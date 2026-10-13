import sys, time, re
import os,pathlib; _r=pathlib.Path(__file__).resolve().parents[2]; sys.path[:0]=[str(_r), str(_r/'packages')]
from edit_plan_jobs import JobStore, JobStoreConfig, job_id_for, _ser, _deser

# --- in-memory fakes mimicking the boto3 call shapes we use ---
class FakeDDB:
    def __init__(self): self.items={}
    def put_item(self, TableName, Item, ConditionExpression=None):
        jid=Item["job_id"]["S"]
        if ConditionExpression and "attribute_not_exists" in ConditionExpression and jid in self.items:
            raise Exception("ConditionalCheckFailedException")
        self.items[jid]=dict(Item)
    def get_item(self, TableName, Key):
        it=self.items.get(Key["job_id"]["S"]); return {"Item":it} if it else {}
    def update_item(self, TableName, Key, UpdateExpression, ExpressionAttributeNames=None,
                    ExpressionAttributeValues=None, ConditionExpression=None):
        jid=Key["job_id"]["S"]; it=self.items.get(jid)
        if it is None: raise Exception("not found")
        cur=it.get("status",{}).get("S")
        v=ExpressionAttributeValues or {}
        # evaluate the conditions we actually use
        if ConditionExpression:
            ce=ConditionExpression
            if "attribute_not_exists" in ce:
                pass  # create path handled by put_item
            else:
                # Faithfully evaluate the exact conditions this code builds.
                def sval(ph): return v.get(ph,{}).get("S")
                ok=False
                # claim_lease: (#s = :q) OR (#s = :r AND lease_until < :now)
                if ":q" in v and ":r" in v and "lease_until < :now" in ce:
                    now=int(v[":now"]["N"]); lease=int(it.get("lease_until",{}).get("N","0"))
                    ok = (cur==sval(":q")) or (cur==sval(":r") and lease<now)
                else:
                    # _set_status require=[...]: OR over :r0,:r1,... == current status
                    allowed={sval(k) for k in v if re.match(r":r\d+$",k)}
                    ok = cur in allowed
                if not ok:
                    raise Exception("ConditionalCheckFailedException")
        # apply SET of #s/status + extras + ADD attempt_count
        if ":new" in v: it["status"]={"S":v[":new"]["S"]}
        if ":run" in v: it["status"]={"S":v[":run"]["S"]}
        if ":lu" in v: it["lease_until"]={"N":v[":lu"]["N"]}
        if "ADD attempt_count :one" in UpdateExpression:
            it["attempt_count"]={"N":str(int(it.get("attempt_count",{}).get("N","0"))+1)}
        for k,val in v.items():
            if k.startswith(":e"):
                # map #eN name back
                it["_extra_"+k]=val
        # extras by name
        names=ExpressionAttributeNames or {}
        for nk,nv in names.items():
            if nk.startswith("#e"):
                idx=nk[2:]; it[nv]=v[f":e{idx}"]
class FakeSQS:
    def __init__(self): self.msgs=[]
    def send_message(self, QueueUrl, MessageBody): self.msgs.append(MessageBody)
class FakeS3:
    def __init__(self): self.obj={}
    def put_object(self, Bucket, Key, Body, ContentType=None, ServerSideEncryption=None):
        assert ServerSideEncryption=="AES256"; self.obj[Key]=Body
    def get_object(self, Bucket, Key):
        import io; return {"Body": io.BytesIO(self.obj[Key] if isinstance(self.obj[Key],bytes) else self.obj[Key])}
    def list_objects_v2(self, Bucket, Prefix): return {"Contents":[{"Key":k} for k in self.obj if k.startswith(Prefix)]}
    def delete_objects(self, Bucket, Delete):
        for o in Delete["Objects"]: self.obj.pop(o["Key"],None)

cfg=JobStoreConfig(table="t", queue_url="q", bucket="b", region="us-east-1")
js=JobStore(cfg, ddb=FakeDDB(), sqs=FakeSQS(), s3=FakeS3())

# 1. idempotency: same operation_id -> same job_id, created once
jid1,c1=js.create_or_get(operation_id="op-A", owner="u1", approach="visual_first",
                         critique_requested=True, staging_prefix="jobs/x/", sheet_order=["m1"])
jid2,c2=js.create_or_get(operation_id="op-A", owner="u1", approach="visual_first",
                         critique_requested=True, staging_prefix="jobs/x/", sheet_order=["m1"])
assert jid1==jid2==job_id_for("op-A"), "deterministic job id"
assert c1 is True and c2 is False, "second submit recovers existing job (no dup)"
# new version -> new op -> new job
jid3,c3=js.create_or_get(operation_id="op-B", owner="u1", approach="storytelling",
                         critique_requested=False, staging_prefix="jobs/y/", sheet_order=[])
assert jid3!=jid1 and c3 is True

# 2. lease: claim once, redelivery blocked while lease live
assert js.claim_lease(jid1) is True, "first claim ok"
assert js.get(jid1)["status"]=="running"
assert js.get(jid1)["attempt_count"]==1
assert js.claim_lease(jid1) is False, "redelivery blocked (live lease)"

# 3. complete is conditional on running
assert js.complete(jid1, {"feasible":True,"segments":[]}, {"planning_mode":"multimodal","sheet_count":1}) is True
got=js.get(jid1)
assert got["status"]=="completed"
assert got["plan"]["feasible"] is True
assert got["diagnostics"]["planning_mode"]=="multimodal"
# can't re-complete a terminal job
assert js.complete(jid1, {}, {}) is False, "no transition out of terminal"

# 4. cancel path
jid4,_=js.create_or_get(operation_id="op-C", owner="u", approach="visual_first",
                        critique_requested=False, staging_prefix="jobs/z/", sheet_order=[])
assert js.request_cancel(jid4)=="cancel_requested"
assert js.is_cancel_requested(jid4) is True
assert js.mark_cancelled(jid4) is True
assert js.get(jid4)["status"]=="cancelled"
# cancel on terminal -> returns terminal status, no transition
assert js.request_cancel(jid4)=="cancelled"

# 5. fail path
jid5,_=js.create_or_get(operation_id="op-D", owner="u", approach="storytelling",
                        critique_requested=False, staging_prefix="jobs/w/", sheet_order=[])
js.claim_lease(jid5)
assert js.fail(jid5,"provider_exhausted","daily quota") is True
assert js.get(jid5)["failure_category"]=="provider_exhausted"

# 6. staging round-trip + SSE + delete
pfx=js.stage_request(jid3, '{"a":1}', [("m1", b"\xff\xd8jpeg1"),("m2", b"\xff\xd8jpeg2")])
body,sheets=js.load_request(pfx, ["m1","m2"])
assert body=='{"a":1}' and sheets[0][0]=="m1" and sheets[0][1]==b"\xff\xd8jpeg1"
js.delete_staging(pfx)
body_gone=True
try: js.load_request(pfx,["m1"]); body_gone=False
except Exception: pass
assert body_gone, "staging deleted on terminal"

print("ALL JOBSTORE TESTS PASSED")
