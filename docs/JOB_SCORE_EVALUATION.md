# Old versus new job score: synthetic evaluation

Fixed fictional facts and listings; expectations authored before running. Labels are agent-authored, not independent human ground truth. No absolute numerical score is labeled correct. Baseline: 46d5956; as_of: 2026-11.

Old uses a faithful outline of the same confirmed records. Old-native uses the existing record_resume.prepare conversion. New uses confirmed records directly. Algorithm differences should be judged against Old; Old-native also measures conversion effects.

| Metric | Old | Old-native | New |
|---|---:|---:|---:|
| Evidence decisions correct | 34 | 33 | 41 |
| False positive evidence | 9 | 8 | 1 |
| False negative evidence | 1 | 3 | 2 |
| Expected requirements undetected | 2 | 2 | 2 |
| Ranking pairs correct | 22 | 15 | 29 |
| Ranking ties | 1 | 14 | 0 |

54 cases; 46 evidence checks; 29 ranking pairs. Undetected requirements count as incorrect, including expected-absent requirements.

## Cases

| Case | Old | Old-native | New | Incorrect evidence decisions (Old / New) |
|---|---:|---:|---:|---|
| python_applied | 100 | 85 | 100 | none / none |
| python_absent | 15 | 0 | 15 | none / none |
| python_negated | 100 | 85 | 15 | Python=True / none |
| python_listed | 66 | 85 | 66 | none / none |
| docker_applied | 100 | 85 | 100 | none / none |
| docker_absent | 15 | 0 | 15 | none / none |
| docker_negated | 100 | 85 | 15 | Docker=True / none |
| docker_listed | 66 | 85 | 66 | none / none |
| kubernetes_applied | 100 | 85 | 100 | none / none |
| kubernetes_absent | 15 | 0 | 15 | none / none |
| kubernetes_negated | 100 | 85 | 15 | Kubernetes=True / none |
| kubernetes_listed | 66 | 85 | 66 | none / none |
| postgresql_applied | 100 | 85 | 100 | none / none |
| postgresql_absent | 15 | 0 | 15 | none / none |
| postgresql_negated | 100 | 85 | 15 | PostgreSQL=True / none |
| postgresql_listed | 66 | 85 | 66 | none / none |
| javascript_applied | 100 | 85 | 100 | none / none |
| javascript_absent | 15 | 0 | 15 | none / none |
| javascript_negated | 100 | 85 | 15 | JavaScript=True / none |
| javascript_listed | 66 | 85 | 66 | none / none |
| terraform_applied | 100 | 85 | 100 | none / none |
| terraform_absent | 15 | 0 | 15 | none / none |
| terraform_negated | 100 | 85 | 15 | Terraform=True / none |
| terraform_listed | 66 | 85 | 66 | none / none |
| negation_not_only | 100 | 85 | 15 | none / Python=False |
| negation_clause_scope | 100 | 85 | 58 | Docker=True / none |
| contact_false_positive | 100 | 85 | 15 | Python=True / none |
| contact_mixed_claim | 100 | 85 | 15 | none / Python=False |
| coursework | 100 | 85 | 83 | none / none |
| alias_postgres | 100 | 85 | 100 | none / none |
| alias_k8s | 100 | 85 | 100 | none / none |
| alternative | 100 | 85 | 100 | none / none |
| alternative_absent | 15 | 0 | 15 | none / none |
| bachelor_met | 100 | 73 | 100 | none / none |
| bsc_met | 87 | 73 | 100 | education=False / none |
| degree_absent | 87 | 73 | 87 | none / none |
| years_met | 100 | 73 | 100 | none / none |
| years_wrong_domain | 13 | 0 | 13 | experience=True / experience=True |
| license_missing | 0 | 0 | 0 | none / none |
| license_met | 60 | 60 | 60 | none / none |
| nontech_nursing_met | 30 | 30 | 30 | rn license=None / rn license=None |
| nontech_nursing_missing | 0 | 0 | 0 | rn license=None / rn license=None |
| preferred_absent | 72 | 56 | 72 | none / none |
| sparse_listing | 100 | 0 | None | none / none |
| duplicate_stuffing | 100 | 85 | 100 | none / none |
| backend_strong | 100 | 73 | 100 | none / none |
| backend_partial | 63 | 37 | 63 | none / none |
| backend_unrelated | 13 | 0 | 13 | none / none |
| frontend_strong | 100 | 73 | 100 | none / none |
| frontend_partial | 63 | 37 | 63 | none / none |
| frontend_unrelated | 13 | 0 | 13 | none / none |
| cloud_strong | 100 | 73 | 100 | none / none |
| cloud_partial | 51 | 24 | 51 | none / none |
| cloud_unrelated | 13 | 0 | 13 | none / none |

## Requirement priority

Mandatory/preferred classification correct: Old 42/46; New 42/46. A missing requirement also fails this check when mandatory.

| Case | Requirement | Expected mandatory | Old mandatory | New mandatory |
|---|---|---|---|---|
| license_missing | cpa license | True | False | False |
| license_met | cpa license | True | False | False |
| nontech_nursing_met | rn license | True | False | False |
| nontech_nursing_missing | rn license | True | False | False |

## Interpretation

Old and New give exactly the same score in 41/54 cases. The six repeated skill families dominate aggregate counts; this is evidence of targeted behavior changes, not broad generalization.

New fixes explicit negation, name-line false positives, BSc recognition and sparse-listing refusal. It loses valid evidence for not-only constructions and a genuine claim containing a URL. Both count unrelated tenure toward a domain-specific experience requirement. Neither correctly marks CPA and RN licenses as mandatory in these examples. RN license is not extracted as its own requirement. A synthetic duplicate-keyword claim still earns full skill credit in both; deciding whether bare mentions should count as applied experience needs a separate rubric decision.

Recommendation: retain confirmed-input and reproducibility improvements, fix the two demonstrated evidence regressions, and evaluate domain-specific experience and mandatory credentials before treating this as a generally better job-fit score. Review labels independently and add unseen examples before tuning.

## Stability

New exact repeats: 54/54. Old exact repeats: 54/54. New whitespace and ignored metadata: 54/54. Old equivalent scores: 54/54.

## Reproduce

From the repository root on Linux/WSL, run `jac run tests/job_score_benchmark.py` (verified with Jac 0.37.21). No database, server or model is required. Fixtures are in `tests/job_score_benchmark_cases.py`. The original evaluation used baseline 46d5956 and a snapshot of the proposed scorer. The benchmark was carried forward to the publication candidate on 1b7c89d; the baseline scorer, confirmed-record converter and vocabulary are unchanged. Outputs overwrite only `output/job-score-eval/`. Source hashes in results.json pin exactly what was measured. comparison.csv provides one row per case.

## Limits

Small synthetic diagnostic set with repeated skill templates. Counts are descriptive; cases are not statistically independent. It does not establish recruiter agreement, hiring probability, numerical calibration, or broad occupation coverage. Confirmation gating and UI behavior require API/UI checks separately. Use fixtures.json for independent relabeling and add unseen real examples before tuning weights. Full outputs, requirement-priority labels and source hashes are in results.json.
