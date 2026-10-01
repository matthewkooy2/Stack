"""Prepared follow-up; use only after renewed physical readiness for sudo.

Classifies discovery metadata without processing it, then guards agent-only start.
Original combined-run result is preserved separately. No secret values emitted.
"""
import subprocess, sys
import stack_worker_activation as base

base.UNITS = ('stack-worker.service',)
base.RESULT_NAME = 'stack-agent-only-activation-result.json'
base.report['activationScope'] = 'agent_only_discovery_off'
extra = r"""
 'discoveryRequestGroups',(SELECT coalesce(json_agg(g),'[]'::json) FROM
   (SELECT CASE WHEN f->>'kind' IN ('search','url') THEN f->>'kind' ELSE 'other' END kind,
     CASE WHEN f->>'status' IN ('queued','scheduled','collecting','complete','review','error') THEN f->>'status' ELSE 'other' END status,
     count(*) count,
     count(*) FILTER (WHERE coalesce((f->>'created_at')::numeric,0)>=extract(epoch FROM timestamptz '2026-10-01 03:39:02+00')) created_since_worker_approval,
     min(to_timestamp((f->>'created_at')::double precision)) oldest_created_utc,
     max(to_timestamp((f->>'created_at')::double precision)) newest_created_utc
    FROM a WHERE arch_type='DiscoveryRequest' GROUP BY 1,2 ORDER BY 1,2) g),
 'unexpiredDiscoveryLeases',(SELECT count(*) FROM a WHERE arch_type='JobSource'
    AND coalesce(f->>'lease','')<>'' AND coalesce((f->>'lease_until')::numeric,0)>extract(epoch FROM now())),
 'expiredRetainedDiscoveryLeases',(SELECT count(*) FROM a WHERE arch_type='JobSource'
    AND (coalesce(f->>'lease','')<>'' OR coalesce((f->>'lease_until')::numeric,0)>0)
    AND coalesce((f->>'lease_until')::numeric,0)<=extract(epoch FROM now())),
 'dueDiscoverySources',(SELECT count(*) FROM a WHERE arch_type='JobSource'
    AND f->>'status' NOT IN ('review','disabled')
    AND coalesce((f->>'next_at')::numeric,0)<=extract(epoch FROM now())
    AND coalesce((f->>'lease_until')::numeric,0)<=extract(epoch FROM now())),
"""
base.QUEUE = base.QUEUE.replace(" 'pendingDiscoveryRequests',", extra + " 'pendingDiscoveryRequests',")

if __name__ == '__main__':
    sys.exit(base.execute(agent_only=True))
