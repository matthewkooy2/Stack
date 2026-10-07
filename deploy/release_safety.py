"""Trusted transactional promotion policy. No data restore or dependency install."""
import time


class Held(RuntimeError):
    pass


def compatibility(approval, prior, candidate, artifact, runtime):
    # A release cannot self-authorize a data/schema compatibility claim.
    if (approval.get('protocol') != 1 or approval.get('prior_commit') != prior
            or approval.get('candidate_commit') != candidate
            or approval.get('artifact_sha256') != artifact
            or approval.get('runtime_contract') != runtime
            or approval.get('data_compatible') is not True
            or approval.get('irreversible_migrations') is not False):
        raise Held('compatibility_review_required')


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
