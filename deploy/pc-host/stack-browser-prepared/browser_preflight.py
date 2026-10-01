"""Infrastructure guards derived from public Stack contracts/runtime source.

Standing permissions are preserved. No job, domain, identity, or credential
contents leave SQL: only booleans, enum shapes, and aggregate counts.
"""
import hashlib,json,re
ACTIONS=('model','browser_fill','submit_application','send_email','calendar_write','gmail_read')
EXTERNAL=('browser_fill','submit_application','send_email','calendar_write')
WORK_HOLDS=('claimableTicketStates','activeRuns','activeRunLeaseOrTimer','activeRunOwnersMissingIdentity',
            'ticketReferenceMismatch','unresolvedActionIntents','enabledAutoModelPolicies','scheduledFollowupTimers')

def policy_sql(owner):
    assert re.fullmatch('[0-9a-f]{32}',owner)
    selections=', '.join("'"+a+"',coalesce(p->'actions' ? '"+a+"',false)" for a in ACTIONS)
    limits=', '.join("'"+a+"',CASE WHEN jsonb_typeof(p->'daily_limits'->'"+a+"')='number' AND (p->'daily_limits'->>'"+a+"')~'^[0-9]+$' THEN (p->'daily_limits'->>'"+a+"')::numeric BETWEEN 1 AND 100 ELSE false END" for a in ACTIONS)
    return r"""
WITH a AS (SELECT id,root_id,arch_type,props->'archetype' f FROM anchors),
mem AS (SELECT *,coalesce(f->'policy','{}'::jsonb) p FROM a WHERE arch_type='AgentMemory'),
candidates AS (SELECT * FROM mem WHERE coalesce(f->>'deleted','false')<>'true'
 AND coalesce(p->'enabled','false'::jsonb)<>'false'::jsonb
 AND coalesce(p->'enabled','null'::jsonb)<>'null'::jsonb),
summary AS (SELECT
 jsonb_typeof(p->'enabled')='boolean' enabledIsBoolean,
 p->'enabled'='true'::jsonb enabled,
 CASE WHEN jsonb_typeof(p->'expires_at')='number' AND (p->>'expires_at')~'^[0-9]+([.][0-9]+)?$'
      THEN CASE WHEN (p->>'expires_at')::numeric>extract(epoch FROM now()) THEN 'unexpired' ELSE 'expired' END
      ELSE 'invalid' END expirationState,
 coalesce(jsonb_typeof(p->'actions'),'missing') actionFieldShape,
 coalesce(jsonb_typeof(p->'daily_limits'),'missing') dailyLimitFieldShape,
 coalesce(jsonb_typeof(p->'domains'),'missing') domainFieldShape,
 CASE WHEN jsonb_typeof(p->'domains')='array' THEN jsonb_array_length(p->'domains') ELSE 0 END domainCount,
 NOT EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p->'actions')='array' THEN p->'actions' ELSE '[]'::jsonb END) x
    WHERE jsonb_typeof(x)<>'string' OR x#>>'{}' NOT IN ('model','browser_fill','submit_application','send_email','calendar_write','gmail_read')) actionValuesValid,
 NOT EXISTS (SELECT 1 FROM jsonb_each(CASE WHEN jsonb_typeof(p->'daily_limits')='object' THEN p->'daily_limits' ELSE '{}'::jsonb END) x
    WHERE key NOT IN ('model','browser_fill','submit_application','send_email','calendar_write','gmail_read')
       OR jsonb_typeof(value)<>'number' OR value#>>'{}' !~ '^[0-9]+$'
       OR CASE WHEN jsonb_typeof(value)='number' AND value#>>'{}' ~ '^[0-9]+$' THEN (value#>>'{}')::numeric NOT BETWEEN 1 AND 100 ELSE true END) dailyLimitValuesValid,
 replace(m.root_id::text,'-','')= '__OWNER__' boundToLocalModelOwner,
 EXISTS(SELECT 1 FROM identity_users u WHERE replace(u.doc->>'root_id','-','')=replace(m.root_id::text,'-','')) ownerHasIdentity,
 json_build_object(__SELECTIONS__) selectedActions,
 json_build_object(__LIMITS__) positiveUserDailyLimits,
 coalesce(p->'analyze_top_matches','false'::jsonb)='true'::jsonb analyzeTopMatches,
 jsonb_typeof(coalesce(p->'analyze_top_matches','false'::jsonb))='boolean' analyzeTopMatchesIsBoolean
 FROM candidates m)
SELECT coalesce(json_agg(json_build_object(
 'enabledIsBoolean',enabledIsBoolean,'enabled',enabled,'expirationState',expirationState,
 'actionFieldShape',actionFieldShape,'dailyLimitFieldShape',dailyLimitFieldShape,'domainFieldShape',domainFieldShape,'domainCount',domainCount,
 'actionValuesValid',actionValuesValid,'dailyLimitValuesValid',dailyLimitValuesValid,
 'boundToLocalModelOwner',boundToLocalModelOwner,'ownerHasIdentity',ownerHasIdentity,
 'selectedActions',selectedActions,'positiveUserDailyLimits',positiveUserDailyLimits,
 'analyzeTopMatches',analyzeTopMatches,'analyzeTopMatchesIsBoolean',analyzeTopMatchesIsBoolean
 )),'[]'::json) FROM summary;
""".replace('__OWNER__',owner).replace('__SELECTIONS__',selections).replace('__LIMITS__',limits)

def source_queue_sql(original):
    # The runtime schedules automatic model work only with BOTH flags selected.
    result=original.replace("coalesce((f->'policy'->>'expires_at')::numeric,0)",
        "CASE WHEN jsonb_typeof(f->'policy'->'expires_at')='number' AND (f->'policy'->>'expires_at')~'^[0-9]+([.][0-9]+)?$' THEN (f->'policy'->>'expires_at')::numeric ELSE 0 END")
    result=result.replace("f->'policy'->>'analyze_top_matches'='true'", "f->'policy'->>'analyze_top_matches'='true' AND f->'policy'->'actions' ? 'model'")
    # Standing Gmail permission alone does not schedule a sync. A connected
    # Google account owned by the same root is also required by agent_schedule.
    return result.replace(" 'enabledGoogleReadPolicies',", """
 'activeRunLeaseOrTimer',(SELECT count(*) FROM r WHERE f->>'status' NOT IN ('completed','cancelled','failed','needs_input','blocked','uncertain','review')
    AND (coalesce(f->>'lease','')<>'' OR coalesce((f->>'lease_until')::numeric,0)>0 OR coalesce((f->>'next_at')::numeric,0)>0)),
 'scheduledFollowupTimers',(SELECT count(*) FROM a c WHERE c.arch_type='AgentContact'
    AND coalesce((c.f->>'next_at')::numeric,0)>0 AND c.f->'data'->>'selected'='true'
    AND coalesce(c.f->'data'->>'stopped','false')<>'true'
    AND EXISTS(SELECT 1 FROM active m WHERE m.root_id=c.root_id
      AND coalesce((c.f->>'followups')::numeric,0) < CASE WHEN jsonb_typeof(m.f->'policy'->'followup_limit')='number'
        AND (m.f->'policy'->>'followup_limit')~'^[0-9]+$' THEN (m.f->'policy'->>'followup_limit')::numeric ELSE 0 END)),
 'scheduledGoogleSyncPolicies',(SELECT count(*) FROM active m WHERE m.f->'policy'->'actions' ? 'gmail_read'
    AND EXISTS(SELECT 1 FROM a c WHERE c.arch_type='AgentConnection' AND c.root_id=m.root_id AND c.f->>'provider'='google' AND c.f->>'state'='connected')),
 'enabledGoogleReadPolicies',""")

def effective_policy_metadata(rows,operator_limits,certified_adapters):
    evidence=[];errors=[]
    for row in rows:
        if row['expirationState']=='expired' and row['enabledIsBoolean']:continue
        valid=(row['enabledIsBoolean'] and row['enabled'] is True and row['expirationState']=='unexpired'
               and row['actionFieldShape']=='array' and row['dailyLimitFieldShape']=='object'
               and row['domainFieldShape']=='array' and 0<=row['domainCount']<=100
               and row['actionValuesValid'] and row['dailyLimitValuesValid'] and row['analyzeTopMatchesIsBoolean'])
        if not valid:errors.append('active_policy_schema_invalid')
        if not row['ownerHasIdentity']:errors.append('active_policy_owner_missing_identity')
        actions={}
        for action in EXTERNAL:
            selected=bool(row['selectedActions'].get(action))
            user_limit=bool(row['positiveUserDailyLimits'].get(action))
            operator_enabled=int(operator_limits.get(action,0))>0
            adapter_gate=(action!='submit_application' or bool(certified_adapters))
            # Destination allowlists/review receipts/remaining usage can only
            # restrict dispatch further; this is a conservative upper bound.
            possible=bool(valid and selected and user_limit and operator_enabled and adapter_gate)
            actions[action]={'selected':selected,'positiveUserDailyLimit':user_limit,
                             'operatorEnabled':operator_enabled,'adapterGateSatisfied':adapter_gate,
                             'dispatchCouldBePermitted':possible}
        evidence.append({'validActivePolicyShape':bool(valid),'boundToLocalModelOwner':row['boundToLocalModelOwner'],
                         'ownerHasIdentity':row['ownerHasIdentity'],'externalActions':actions,
                         'selectedModelPermission':bool(row['selectedActions'].get('model')),
                         'selectedGmailReadPermission':bool(row['selectedActions'].get('gmail_read')),
                         'analyzeTopMatches':row['analyzeTopMatches'],
                         'destinationAllowlistPresent':row['domainCount']>0})
    return {'activePolicyMetadata':evidence,'schemaBlockers':sorted(set(errors)),
            'anyExternalDispatchPotential':any(a['dispatchCouldBePermitted'] for row in evidence for a in row['externalActions'].values()),
            'standingPermissionsModified':False}

def blockers(queue,policy):
    result=[key for key in WORK_HOLDS if queue[key]]
    if queue['scheduledGoogleSyncPolicies']:result.append('scheduledGoogleSyncPolicies')
    if queue['queuedNotifications'] and queue['pushDevices']:result.append('pending_push_delivery')
    result+=policy['schemaBlockers']
    # No policy selection alone blocks infrastructure. config_guard independently
    # preserves zero operator quotas. Any executable work is held for review.
    return sorted(set(result))
