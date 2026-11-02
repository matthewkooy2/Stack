"""Seed ONLY the staged local jobs lab; no production credentials or graph writes."""
import os;
import time;
import json;
import from pathlib { Path }
import from jaclang.runtime.runtime { JacRuntime }
import from core.catalog { CatalogJob, CatalogTitles, JobAlias, _rebuild_title_index }
import from scripts.jobs_lab_data { records, manifest, FIXTURE_VERSION, needs_seed, bind_catalog, configure_shared_root }
with entry {
    if os.environ.get("JAC_DB_URL") or Path.cwd().name!="app" or not Path.cwd().parent.name.startswith("jobs-lab") {
        raise RuntimeError("Run the seed through scripts/jobs-lab.py in its isolated staged app.");
    }
    count=int(os.environ.get("STACK_JOBS_LAB_COUNT","40000"));
    configure_shared_root();
    store=JacRuntime.get_context().mem.store;
    if needs_seed(store,count) {
        bind_catalog(store,False);JacRuntime.get_context().mem.abort();
        jobs=[root.shared --> [?:CatalogJob]];
        if len(jobs)>count { raise RuntimeError("Lab has more jobs than requested. Choose a different --name; existing accounts are preserved."); }
        existing={j.key:j for j in jobs};
        marker=Path("storage/jobs-lab/manifest.json");
        refresh=not marker.exists() or json.loads(marker.read_text()).get("fixture_version")!=FIXTURE_VERSION;
        if len(jobs)<count or refresh {
            i=0;
            for data in records(count) {
                old=existing.get(data["id"]);
                if old is not None {
                    if not refresh { continue; }
                    old.data=data;old.match_title=data["title"];old.checked_at=time.time();
                } else {
                    j=root.shared ++> CatalogJob(key=data["id"],canonical_url=data["canonical_url"],identity=data["identity"],data=data,checked_at=time.time(),discovered_at=time.time(),match_title=data["title"]);
                    grant(j,level=AccessLevel.READ);
                }
                alias="jobs-lab:"+data["source_job_id"];
                if not [root.shared --> [?:JobAlias, key==alias]] { root.shared ++> JobAlias(key=alias,target=data["id"]); }
                i+=1;
                if i%500==0 { commit();print(f"Prepared {i}/{count} synthetic listings",flush=True); }
            }
            commit();
        }
        for job in jobs { if job.checked_at<time.time()-86400 { job.checked_at=time.time(); } }
        _rebuild_title_index();commit();manifest(count);
        bind_catalog(store,True);JacRuntime.get_context().mem.abort();
    }
    print(f"Synthetic catalog ready: {count} listings",flush=True);
}
