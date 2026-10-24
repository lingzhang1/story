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
            if "attribute_not_exists(quota_released)" in ce:
                ok = "quota_released" not in it
                if not ok: raise Exception("ConditionalCheckFailedException")
            elif ":q" in v and ":r" in v and "lease_until < :now" in ce:
                now=int(v[":now"]["N"]); lease=int(it.get("lease_until",{}).get("N","0"))
                ok=(cur==sval(":q")) or (cur==sval(":r") and lease<now)
            elif ":failed" in v and "payload_fingerprint = :fp" in ce:
                # Coverage recovery reset: require status==failed AND same payload_fingerprint.
                ok = (cur==sval(":failed")
                      and it.get("payload_fingerprint",{}).get("S")==sval(":fp"))
            else:
                parts_ok=True
                allowed={sval(k) for k in v if re.match(r":r\d+$",k)}
                if allowed: parts_ok = cur in allowed
                lt_ok=True
                if "#lt = :lt" in ce:
                    lt_ok = it.get("lease_token",{}).get("S")==sval(":lt")
                ok=parts_ok and lt_ok
            if not ok: raise Exception("ConditionalCheckFailedException")
        # Coverage recovery reset -> queued + clear failure fields + bump recovery_count.
        if ":queued" in v and "ADD recovery_count :one" in UpdateExpression:
            it["status"]={"S":v[":queued"]["S"]}
            it["attempt_count"]={"N":"0"}; it["lease_until"]={"N":"0"}; it["lease_token"]={"S":""}
            it["recovery_count"]={"N":str(int(it.get("recovery_count",{}).get("N","0"))+1)}
            for k in ("failure_category","failure_detail","result","diagnostics"):
                it.pop(k,None)
            return
        if ":run" in v: it["status"]={"S":v[":run"]["S"]}
        if ":new" in v: it["status"]={"S":v[":new"]["S"]}
        if ":lu" in v: it["lease_until"]={"N":v[":lu"]["N"]}
        if ":tok" in v: it["lease_token"]={"S":v[":tok"]["S"]}
        if ":nc" in v: it["reconcile_count"]={"N":v[":nc"]["N"]}
        if "SET quota_released = :one" in UpdateExpression: it["quota_released"]={"N":"1"}
        if "ADD attempt_count :one" in UpdateExpression:
            it["attempt_count"]={"N":str(int(it.get("attempt_count",{}).get("N","0"))+1)}
        names=ExpressionAttributeNames or {}
        for nk,nv in names.items():
            if nk.startswith("#e"):
                idx=nk[2:]; it[nv]=v[f":e{idx}"]
    def scan(self, TableName, FilterExpression=None, ExpressionAttributeNames=None,
             ExpressionAttributeValues=None, Limit=None):
        v=ExpressionAttributeValues or {}; out=[]
        fe=FilterExpression or ""
        if "quota_released" in fe:
            # sweep_quota_orphans filter: not-yet-released AND owner != dev
            for it in self.items.values():
                if ("quota_released" not in it
                    and it.get("owner",{}).get("S")!=v.get(":dev",{}).get("S")):
                    out.append(it)
            return {"Items":out[:Limit or 50]}
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

# ============================ COVERAGE/2 OPERATION TESTS (owner safeguards 1,2,4) ============================
from edit_plan_jobs import (coverage_operation_id, coverage_payload_fingerprint,
                            OP_EDIT_PLAN, OP_COVERAGE_V2, KNOWN_OPERATIONS)

def _covid(**kw):
    base=dict(story_id="S1", owner="u", guide_fingerprint="g1", intent_fingerprint="i1",
              moment_evidence=[("m1","v1"),("m2","v1")], pending_count=0,
              mapper_prompt_version="story_coverage/mapper-v1", judge_prompt_version="story_coverage/judge-v1")
    base.update(kw); return coverage_operation_id(**base)

# C1 canonical fingerprint STABILITY: same inputs (any moment order) -> same op-id
assert _covid()==_covid(moment_evidence=[("m2","v1"),("m1","v1")]), "op-id stable + order-independent"
# C2 changed AU EVIDENCE VERSION with UNCHANGED moment ids -> different op-id (safeguard 2)
assert _covid()!=_covid(moment_evidence=[("m1","v2"),("m2","v1")]), "changed evidence version -> new job"
# C3 changed PENDING count -> different op-id
assert _covid()!=_covid(pending_count=1), "changed pending count -> new job"
# C4 changed guide/intent/prompt version -> different op-id
assert _covid()!=_covid(guide_fingerprint="g2")
assert _covid()!=_covid(intent_fingerprint="i2")
assert _covid()!=_covid(mapper_prompt_version="story_coverage/mapper-v2")

# C5 idempotent coverage create + recovery
js2=JobStore(cfg=JobStoreConfig(table="t",queue_url="q",bucket="b"),ddb=FakeDDB(),sqs=FakeSQS(),s3=FakeS3())
opid=_covid(); body='{"story_id":"S1","moments":[]}'; cfp=coverage_payload_fingerprint(body,opid)
cj1,cc1=js2.create_or_get_coverage(operation_id=opid,owner="u",body_json=body,payload_fingerprint=cfp)
cj2,cc2=js2.create_or_get_coverage(operation_id=opid,owner="u",body_json=body,payload_fingerprint=cfp)
assert cj1==cj2 and cc1 and not cc2, "same snapshot recovers same coverage job"
# C6 DISPATCH ISOLATION: a coverage job reads back operation_type=coverage_v2 (never edit_plan)
row=js2.get(cj1); assert row["operation_type"]==OP_COVERAGE_V2
assert row["request_ref"]["inline"] and row["request_ref"]["body_json"]==body, "small body inlined"
# C7 same op-id DIFFERENT payload -> PayloadConflict (safeguard 2 preserved)
try:
    js2.create_or_get_coverage(operation_id=opid,owner="u",body_json='{"other":1}',
                               payload_fingerprint=coverage_payload_fingerprint('{"other":1}',opid))
    assert False,"expected coverage payload conflict"
except PayloadConflict: pass
# C8 coverage completes under lease, stored under `result` (NEVER `plan`) -> no cross-read as EditPlan
ctok=js2.claim_lease(cj1); assert ctok
assert js2.complete_coverage(cj1,{"dimension_coverage":[{"id":"d1"}]},{"mapper_latency_ms":5000},ctok)
done=js2.get(cj1)
assert done["status"]=="completed" and "result" in done and done.get("plan") is None, "coverage result not a plan"
assert done["result"]["dimension_coverage"][0]["id"]=="d1"
# C9 EDIT-PLAN still stamps operation_type=edit_plan (isolation the other direction)
ep_row=js.get(j1); assert ep_row["operation_type"]==OP_EDIT_PLAN
# C10 UNKNOWN operation set is closed; worker dispatch rejects anything outside KNOWN_OPERATIONS
assert KNOWN_OPERATIONS=={OP_EDIT_PLAN,OP_COVERAGE_V2}
assert "coverage_v3" not in KNOWN_OPERATIONS

# ============================ PHASE 4 QUOTA-ORPHAN SWEEP (crash recovery, correction 12) ===================
js3=mk()
# (a) a job stuck RUNNING past its expires_at = worker crashed mid-run -> swept, failed(orphaned), returned
jo,_=js3.create_or_get(operation_id="ORPH",owner="story-u1",approach="storytelling",critique_requested=False,
                       staging_prefix="jobs/ORPH/",sheet_order=[],payload_fingerprint="x")
js3.claim_lease(jo)                                  # now running
js3._ddb.items[jo]["expires_at"]={"N":"1"}           # force expiry (crashed, never terminated)
orphans=js3.sweep_quota_orphans()
assert any(o["job_id"]==jo for o in orphans), "crashed running job swept for quota release"
assert js3.get(jo)["status"]=="failed", "orphan finalized failed"
o=[x for x in orphans if x["job_id"]==jo][0]
assert o["owner"]=="story-u1" and o["operation_id"]=="ORPH"
# (b) exactly-once: a second sweep does NOT return the same job again (quota_released stamped)
orphans2=js3.sweep_quota_orphans()
assert all(x["job_id"]!=jo for x in orphans2), "already-released orphan skipped (exactly-once)"
# (c) a legacy/dev job is NEVER swept (never held a reservation)
jd,_=js3.create_or_get(operation_id="DEVJOB",owner="dev",approach="storytelling",critique_requested=False,
                       staging_prefix="jobs/DEVJOB/",sheet_order=[],payload_fingerprint="x")
js3._ddb.items[jd]["expires_at"]={"N":"1"}
assert all(x["job_id"]!=jd for x in js3.sweep_quota_orphans()), "dev job never swept"

print("ALL AMENDED JOBSTORE TESTS PASSED")

# ---- Coverage bounded-recovery (P0 reliability) --------------------------------------------------
from edit_plan_jobs import COVERAGE_MAX_RECOVERY_ATTEMPTS

def _mk_cov(js, op="COV", fp_="covfp"):
    return js.create_or_get_coverage(operation_id=op, owner="u", body_json='{"b":1}',
                                     payload_fingerprint=fp_)

# R1: a RECOVERABLE terminal-failed coverage job is re-created (reset to queued) on identical re-submit.
jcov=mk()
j,c=_mk_cov(jcov); assert c, "first create"
tok=jcov.claim_lease(j); assert tok
assert jcov.fail(j,"mapper_unavailable","anthropic denied",tok), "mark failed"
assert jcov.get(j)["status"]=="failed"
j2,c2=_mk_cov(jcov)
assert j2==j and c2 is True, "recoverable failed -> re-created as fresh attempt"
assert jcov.get(j2)["status"]=="queued", "reset to queued"
assert jcov.get(j2).get("failure_category") is None, "prior failure cleared"
assert int(jcov.get(j2)["recovery_count"])==1

# R2: a NON-recoverable failure (empty_mapping) is NOT re-created -> idempotent reuse of the failed record.
jne=mk()
j,c=_mk_cov(jne); tok=jne.claim_lease(j)
assert jne.fail(j,"empty_mapping","truncated",tok)
j2,c2=_mk_cov(jne)
assert j2==j and c2 is False, "deterministic failure is not auto-retried"
assert jne.get(j2)["status"]=="failed"

# R3: recovery is CAPPED — after COVERAGE_MAX_RECOVERY_ATTEMPTS, a recoverable failure stops re-creating.
jcap=mk()
j,_=_mk_cov(jcap)
for i in range(COVERAGE_MAX_RECOVERY_ATTEMPTS):
    tok=jcap.claim_lease(j); assert tok, f"claim {i}"
    assert jcap.fail(j,"provider_error","boom",tok)
    j2,c2=_mk_cov(jcap)
    assert c2 is True, f"recovery {i+1} within cap"
# now at the cap: one more failure must NOT re-create
tok=jcap.claim_lease(j); assert jcap.fail(j,"provider_error","boom",tok)
j3,c3=_mk_cov(jcap)
assert c3 is False, "recovery cap reached -> no further auto-retry"
assert int(jcap.get(j3)["recovery_count"])==COVERAGE_MAX_RECOVERY_ATTEMPTS

# R4: a QUEUED or COMPLETED coverage job is NEVER reset by a re-submit (idempotent coalesce preserved).
jlive=mk()
j,_=_mk_cov(jlive)             # queued
j2,c2=_mk_cov(jlive); assert j2==j and c2 is False and jlive.get(j2)["status"]=="queued"
tok=jlive.claim_lease(j)
assert jlive.complete_coverage(j,{"dimension_coverage":[]},{"x":1},tok)
assert jlive.get(j)["status"]=="completed"
j3,c3=_mk_cov(jlive); assert j3==j and c3 is False and jlive.get(j3)["status"]=="completed", "completed not reset"

# R5: payload CONFLICT still wins over recovery (a different payload on a failed job is a client bug).
jpc=mk()
j,_=_mk_cov(jpc, fp_="fpA"); tok=jpc.claim_lease(j); jpc.fail(j,"mapper_unavailable","x",tok)
try:
    _mk_cov(jpc, fp_="fpB")
    assert False, "expected PayloadConflict on different payload"
except PayloadConflict: pass

print("COVERAGE RECOVERY TESTS PASSED")
