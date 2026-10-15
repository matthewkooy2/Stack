#!/usr/bin/env python3
"""Run the approved existing backend safety cases, in separate Jac runtimes."""
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SUITES = {
    'offline': [
        'tests.test_bootstrap', 'tests.test_pdf_safety', 'tests.test_gateway',
        'tests.test_backend_release', 'tests.test_ios_signing',
        'tests.test_fixture_provenance', 'tests.test_resume_review_fixture',
        'tests.test_ios_swift_static', 'tests.test_ios_xcresult_attachments',
        'tests.test_ios_native_proof', 'tests.test_ios_core', 'tests.test_affected_checks',
    ],
    'permissions': [
        'tests.test_agents.Contracts.test_disabled_by_default',
        'tests.test_agents.Contracts.test_exact_domain_and_expiry',
        'tests.test_agents.Contracts.test_wildcards_and_invalid_limits',
        'tests.test_agents.Contracts.test_budget_unset',
        'tests.test_agents.Contracts.test_budget_reservation_counts_payload',
        'tests.test_agents.Contracts.test_sandbox_requires_pinned_image_and_isolation',
        'tests.test_agent_providers.Providers.test_default_api_remains_disabled',
        'tests.test_agent_providers.Providers.test_subscription_needs_no_account_binding_cap_or_money',
        'tests.test_agent_providers.Providers.test_api_prices_and_budgets_still_required',
        'tests.test_agent_providers.Providers.test_cli_environment_drops_secrets_and_provider_overrides',
        'tests.test_agent_providers.Providers.test_subscription_has_no_http_fallback_or_dollar_estimate',
    ],
    'transcription': [
        'tests.test_transcription.Jobs.test_response_loss_replay_restart_worker_finish_and_edit',
        'tests.test_transcription.Jobs.test_ownership_and_content_identity',
        'tests.test_transcription.Jobs.test_cancel_delete_account_delete_reject_late_results',
        'tests.test_transcription.Jobs.test_phone_original_is_completed_durable_and_never_claimed',
        'tests.test_interview_contract',
    ],
    'transcription-api': ['tests.test_transcription_api'],
    'resume': [
        'tests.test_resume_processing.ResumeProcessing.test_pdf_import_is_reviewable_without_confirming_facts_implicitly',
        'tests.test_resume_processing.ResumeProcessing.test_details_persist_reorder_delete_and_enforce_owner_revision',
        'tests.test_resume_processing.ResumeProcessing.test_replacement_deletion_and_ownership_reject_stale_work',
    ],
}
JAC_SUITES = [
    'google_signin_tests.jac', 'google_signin_gateway_tests.jac',
    'pdf_upload_security_tests.jac', 'provider_workflow_tests.jac',
    'autofill_workflow_tests.jac', 'application_retirement_tests.jac',
]


def main():
    os.chdir(ROOT)
    sys.path.insert(0, str(ROOT))
    selector = os.environ.get('STACK_CORE_SUITE')
    if selector:
        suite = unittest.defaultTestLoader.loadTestsFromNames(SUITES[selector])
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        return 0 if result.wasSuccessful() and result.testsRun and not result.skipped else 1
    sys.path.insert(0, str(ROOT / 'scripts'))
    import bootstrap
    env = bootstrap.environment(ROOT)
    env.update(JAC_DB_SCRATCH='1', JAC_TEST_JOBS='0', PYTHONPATH=str(ROOT))
    for name in SUITES:
        start = time.monotonic()
        subprocess.run([str(ROOT / 'scripts/jac'), 'run', '--no-serve', __file__],
                       env=dict(env, STACK_CORE_SUITE=name), check=True)
        print(f'Core {name}: {time.monotonic() - start:.1f}s', flush=True)
    for name in JAC_SUITES:
        subprocess.run([str(ROOT / 'scripts/jac'), 'test', 'tests/' + name], env=env, check=True)
    subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s',
                    'deploy/startup', '-p', 'test_startup.py', '-v'], env=env, check=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
