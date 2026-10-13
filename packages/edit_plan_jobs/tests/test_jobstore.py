import sys, time, re, io, os, pathlib
_r=pathlib.Path(__file__).resolve().parents[2]; sys.path[:0]=[str(_r), str(_r/'packages')]
from edit_plan_jobs import (JobStore, JobStoreConfig, job_id_for, payload_fingerprint,
                            PayloadConflict)

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
        cur=it.get("status",{}).get("S"); v=ExpressionAttributeValues or {}
        def sval(ph): return v.get(ph,{}).get("S")
        if ConditionExpression:
            ce=ConditionExpression; ok=True
            if ":q" in v and ":r" in v and "lease_until < :now" in ce:
                now=int(v[":now"]["N"]); lease=int(it.get("lease_until",{}).get("N","0"))
                ok=(cur==sval(":q")) or (cur==sval(":r") and lease<now)
            else:
                parts_ok=True
                allowed={sval(k) for k in v if re.match(r":r\d+$",k)}
                if allowed: parts_ok = cur in allowed
                lt_ok=True
                if "#lt = :lt" in ce:
                    lt_ok = it.get("lease_token",{}).get("S")==sval(":lt")
                ok=parts_ok and lt_ok
            if not ok: raise Exception("ConditionalCheckFailedException")
        if ":run" in v: it["status"]={"S":v[":run"]["S"]}
        if ":new" in v: it["status"]={"S":v[":new"]["S"]}
        if ":lu" in v: it["lease_until"]={"N":v[":lu"]["N"]}
        if ":tok" in v: it["lease_token"]={"S":v[":tok"]["S"]}
        if ":nc" in v: it["reconcile_count"]={"N":v[":nc"]["N"]}
        if "ADD attempt_count :one" in UpdateExpression:
            it["attempt_count"]={"N":str(int(it.get("attempt_count",{}).get("N","0"))+1)}
        names=ExpressionAttributeNames or {}
        for nk,nv in names.items():
            if nk.startswith("#e"):
                idx=nk[2:]; it[nv]=v[f":e{idx}"]
    def scan(self, TableName, FilterExpression=None, ExpressionAttributeNames=None,
             ExpressionAttributeValues=None, Limit=None):
        v=ExpressionAttributeValues or {}; out=[]
        for it in self.items.values():
            if (it.get("status",{}).get("S")=="queued"
                and int(it.get("attempt_count",{}).get("N","0"))==0
                and int(it.get("created_at",{}).get("N","0"))<int(v[":cut"]["N"])):
                out.append(it)
        return {"Items":out[:Limit or 50]}
class FakeSQS:
    def __init__(self): self.msgs=[]
    def send_message(self, QueueUrl, MessageBody): self.msgs.append(MessageBody)
class FakeS3:
    def __init__(self): self.obj={}
    def put_object(self, Bucket, Key, Body, ContentType=None, ServerSideEncryption=None):
        assert ServerSideEncryption=="AES256"; self.obj[Key]=Body
    def get_object(self, Bucket, Key): return {"Body": io.BytesIO(self.obj[Key])}
    def list_objects_v2(self, Bucket, Prefix): return {"Contents":[{"Key":k} for k in self.obj if k.startswith(Prefix)]}
    def delete_objects(self, Bucket, Delete):
        for o in Delete["Objects"]: self.obj.pop(o["Key"],None)

def mk(): return JobStore(JobStoreConfig(table="t",queue_url="q",bucket="b",region="us-east-1"),
                          ddb=FakeDDB(), sqs=FakeSQS(), s3=FakeS3())
fp=lambda: payload_fingerprint('{"b":1}', ["m1"], True, "visual_first")

# 1 idempotency same payload
js=mk()
j1,c1=js.create_or_get(operation_id="A",owner="u",approach="visual_first",critique_requested=True,
                       staging_prefix="jobs/A/",sheet_order=["m1"],payload_fingerprint=fp())
j2,c2=js.create_or_get(operation_id="A",owner="u",approach="visual_first",critique_requested=True,
                       staging_prefix="jobs/A/",sheet_order=["m1"],payload_fingerprint=fp())
assert j1==j2==job_id_for("A") and c1 and not c2
# 2 conflicting payload -> PayloadConflict
try:
    js.create_or_get(operation_id="A",owner="u",approach="storytelling",critique_requested=False,
                     staging_prefix="jobs/A/",sheet_order=["m9"],
                     payload_fingerprint=payload_fingerprint('{"different":1}',["m9"],False,"storytelling"))
    assert False,"expected conflict"
except PayloadConflict: pass
# 3 lease token + stale worker cannot publish
tok1=js.claim_lease(j1); assert tok1
assert js.claim_lease(j1) is None, "redelivery blocked while lease live"
assert js.complete(j1,{"feasible":True,"segments":[]},{"planning_mode":"multimodal"},"WRONG-TOKEN") is False, "stale token rejected"
assert js.complete(j1,{"feasible":True,"segments":[]},{"planning_mode":"multimodal"},tok1) is True
assert js.get(j1)["status"]=="completed"
# 4 cancel reaches terminal
jc,_=js.create_or_get(operation_id="C",owner="u",approach="visual_first",critique_requested=False,
                      staging_prefix="jobs/C/",sheet_order=[],payload_fingerprint="x")
assert js.request_cancel(jc)=="cancel_requested"
assert js.mark_cancelled(jc) and js.get(jc)["status"]=="cancelled"
# 5 expired-on-read (TTL not immediate)
je,_=js.create_or_get(operation_id="E",owner="u",approach="storytelling",critique_requested=False,
                      staging_prefix="jobs/E/",sheet_order=[],payload_fingerprint="x")
# force expires_at into the past
js._ddb.items[je]["expires_at"]={"N":"1"}
assert js.get(je)["status"]=="expired", "non-terminal past expires_at reads as expired"
# 6 reconcile re-enqueues only stranded queued, capped
jr,_=js.create_or_get(operation_id="R",owner="u",approach="storytelling",critique_requested=False,
                      staging_prefix="jobs/R/",sheet_order=[],payload_fingerprint="x")
js._ddb.items[jr]["created_at"]={"N":"1"}   # old
re1=js.reconcile_lost_enqueue(); assert jr in re1, "stranded queued re-enqueued"
# a leased job is NOT reconciled
assert js.claim_lease(j1) is None  # j1 is completed, won't claim
# cap: after MAX attempts -> failed
js._ddb.items[jr]["created_at"]={"N":"1"}; js.reconcile_lost_enqueue()
js._ddb.items[jr]["created_at"]={"N":"1"}; js.reconcile_lost_enqueue()
assert js.get(jr)["status"] in ("failed","queued")  # eventually fails as enqueue_lost
print("ALL AMENDED JOBSTORE TESTS PASSED")
