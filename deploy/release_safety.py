"""Trusted transactional promotion policy. No data restore or dependency install."""
import time


class Held(RuntimeError):
    pass


def compatibility(approval, prior, candidate, prior_browser=None, candidate_browser=None):
    """Root-approved epoch, independently checked against actual payload hashes.

    Complete inventories prevent added/deleted files bypassing the frozen set.
    Only explicitly reviewed routine files may differ between compatible releases.
    Artifact revision/digest validation remains the receiver's separate obligation.
    """
    if (approval.get('protocol') != 2 or not isinstance(approval.get('epoch'), str)
            or not 1 <= len(approval['epoch']) <= 64
            or approval.get('data_compatible') is not True
            or approval.get('irreversible_migrations') is not False):
        raise Held('compatibility_review_required')
    def inventory(policy, old, new, routine):
        if (not isinstance(policy, dict) or not isinstance(routine, list)
                or len(set(routine)) != len(routine) or not set(routine) <= set(policy)
                or set(old) != set(policy) or set(new) != set(policy)):
            raise Held('compatibility_inventory')
        if any(not isinstance(h, str) or len(h) != 64 or
               any(c not in '0123456789abcdef' for c in h) for h in policy.values()):
            raise Held('compatibility_inventory')
        if any(old[n] != h or new[n] != h for n, h in policy.items() if n not in routine):
            raise Held('compatibility_frozen_source')
    routine = approval.get('routine_files', [])
    if not isinstance(routine, list) or 'jac.toml' in routine:
        raise Held('compatibility_runtime')
    inventory(approval.get('files'), prior, candidate, routine)
    # jac.toml is the entire server-filtered configuration, not the narrower
    # dependency/database contract. Entry points and placement remain frozen.
    if 'jac.toml' not in approval['files']:
        raise Held('compatibility_runtime')
    old, new = prior_browser or {}, candidate_browser or {}
    inventory(approval.get('browser_files'), old.get('files', {}), new.get('files', {}),
              approval.get('routine_browser_files', []))
    contract = approval.get('browser_contract')
    if not isinstance(contract, dict) or old.get('contract', {}) != contract or new.get('contract', {}) != contract:
        raise Held('compatibility_browser_contract')


def wait_ready(check, commit, *, attempts=20, interval=3, deadline=60,
               clock=time.monotonic, sleep=time.sleep):
    """Bound both attempts and wall time; check itself has a transport timeout."""
    began = clock()
    stage = 'readiness'
    for attempt in range(1, attempts + 1):
        remaining = deadline - (clock() - began)
        if remaining <= 0:
            break
        try:
            check(commit, remaining)
            if clock() - began > deadline:
                raise Held('readiness_timeout')
            return {'commit': commit, 'attempts': attempt,
                    'elapsed_ms': int((clock() - began) * 1000), 'checks': 'passed'}
        except Held as error:
            stage = str(error)
        if attempt < attempts:
            sleep(min(interval, max(0, deadline - (clock() - began))))
    raise Held(stage)


def transaction(prior, candidate, *, stop, install, start, check, restore,
                persist, finalize, wait=wait_ready):
    """Lock must be held by caller through receipt persistence and recovery.

    Never restore a byte until ALL writers are confirmed stopped. Failed recovery
    leaves a durable hold, and every failed candidate remains a failed CD job.
    """
    result = {'commit': candidate, 'prior_commit': prior, 'status': 'deploying',
              'stage': 'stop', 'recovery': 'not_needed'}
    persist(result)
    try:
        stop()
        result['stage'] = 'install'
        install()
        result['stage'] = 'start'
        start()
        result['stage'] = 'readiness'
        result['candidate_checks'] = wait(check, candidate)
        result['stage'] = 'commit'
        finalize()
        result.update(status='healthy', stage='complete')
        persist(result)
        return result
    except Exception as error:
        failed_stage = result['stage']
        if isinstance(error, Held):
            # Only trusted stage identifiers, never raw response/host errors.
            result['failing_check'] = str(error)
        result.update(status='recovering', failing_stage=failed_stage, recovery='pending')
        try:
            persist(result)
        except Exception:
            result['receipt_write_failed'] = True
        try:
            result['stage'] = 'recovery_stop'
            stop()
            result['stage'] = 'recovery_restore'
            restore()
            result['stage'] = 'recovery_start'
            start()
            result['stage'] = 'recovery_readiness'
            result['prior_checks'] = wait(check, prior)
            result.update(status='failed', stage=failed_stage, recovery='healthy')
        except Exception:
            recovery_stage = result['stage']
            # Best effort quiesce: do not start more writers after uncertain restore.
            try:
                stop()
                result['writers_stopped'] = True
            except Exception:
                result['writers_stopped'] = False
            result.update(status='held', recovery='failed', recovery_stage=recovery_stage,
                          stage=failed_stage)
        persist(result)
        return result
