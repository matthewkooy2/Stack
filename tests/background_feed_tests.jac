"""Regression for #105 and #107: requests never rebuild the catalog view or prepare feeds,
and the view keeps serving while it is rebuilt in the background."""
import tempfile;
import threading;
import time;
import from unittest.mock { patch }
import from jaclang.runtime.runtime { JacRuntime }
import core.automation as a;
import core.catalog as catalog;
import main as app;

def refuse(*args: any) -> any { raise AssertionError("A request did background catalog work inline"); }

def account_context(directory: str) -> any {
    ctx=JacRuntime.create_j_context(None,base_path_dir=directory);JacRuntime.set_context(ctx);
    root ++> a.AgentMemory();
    root ++> app.Profile(onboarded=True);
    root ++> app.MatchPreferences(roles="Software engineer");
    root ++> app.Settings(tailored_backfilled=True);commit();
    return ctx;
}

def reset_cache -> None {
    catalog._catalog_cache.update({"root":"","at":0.0,"rows":{},"building":False,"pending":{},"stale":False,"duration":0.0});
}

def row(key: str, title: str = "Software Engineer", expires_at: float = 0.0) -> dict[str, any] {
    return {"id":key,"title":title,"company":"Fixture","active":True,"expires_at":expires_at,"posted_at":time.time(),
        "description":"Build software.","qualifications":"","match":{"score":1.0},"timeline":{}};
}

test "requests never rebuild the catalog view or prepare a feed" {
    with tempfile.TemporaryDirectory(prefix="stack-feeds-inline-") as directory {
        previous=JacRuntime.peek_context();ctx=account_context(directory);reset_cache();
        try {
            with patch.object(catalog,"_catalog_rebuild",refuse), patch.object(catalog,"_prepare_job_feed",refuse) {
                first=catalog.search_jobs("Software engineer",{});
                assert first["updating"] and first["jobs"]==[];
                assert not catalog.save_search("Data analyst",{}).get("error");
                assert catalog.search_jobs("Data analyst",{})["updating"];
                assert app.bootstrap()["user_id"]==jid(root);
                assert not app.save_profile("Fixture","Nurse","United States","Any",False).get("error");
            }
            # Repeated searches leave one request per account, carrying the latest search.
            me=jid(root);requests=[root.shared --> [?:catalog.FeedRequest, owner==me]];
            assert len(requests)==1;
            assert requests[0].search["query"]=="Data analyst";
        } finally { reset_cache();ctx.close();if previous is not None { JacRuntime.set_context(previous); } }
    }
}

test "the view keeps serving its snapshot while a rebuild runs, and keeps it if the rebuild fails" {
    reset_cache();
    catalog._catalog_cache.update({"root":"fixture","at":time.time(),"rows":{"job_old":row("job_old")}});
    started=threading.Event();release=threading.Event();
    def slow_view(j: any) -> dict[str, any] { started.set();release.wait(10);return row("job_new"); }
    def build -> None {
        with patch.object(catalog,"_job_view",slow_view) {
            # One fixture job, so the rebuild blocks inside the per-job processing.
            with patch.object(catalog,"_shared_jobs",lambda { [catalog.CatalogJob(key="job_new",canonical_url="u",identity="i",data={})]; }) {
                catalog._catalog_rebuild();
            }
        }
    }
    worker=threading.Thread(target=build);worker.start();
    try {
        assert started.wait(10);
        began=time.time();records=catalog._catalog_records();
        assert time.time()-began<1.0;
        assert [r["id"] for r in records]==["job_old"];
        assert catalog._catalog_rebuild()==-1;
        # An update committed mid-rebuild survives the swap.
        catalog._cache_put(row("job_edit","Edited title"));
    } finally { release.set();worker.join(10); }
    rows=catalog._catalog_cache["rows"];
    assert "job_new" in rows and "job_edit" in rows and rows["job_edit"]["title"]=="Edited title";
    assert not catalog._catalog_cache["building"];
    def broken -> list[any] { raise RuntimeError("database unavailable"); }
    with patch.object(catalog,"_shared_jobs",broken) {
        try { catalog._catalog_rebuild();assert False; } except RuntimeError { }
    }
    assert "job_new" in catalog._catalog_cache["rows"] and not catalog._catalog_cache["building"];
    reset_cache();
}

test "served cards drop expired and closed jobs and show listing edits" {
    reset_cache();
    catalog._catalog_cache.update({"root":"fixture","at":time.time(),"rows":{
        "job_a":row("job_a","Edited title"),"job_b":{**row("job_b"),"active":False},"job_c":row("job_c",expires_at=time.time()-10)}});
    with patch.object(catalog,"_catalog_status",lambda { {"ready":True}; }) {
        cards=catalog._current_cards([row("job_a"),row("job_b"),row("job_c"),row("job_gone")],26);
    }
    assert [c["id"] for c in cards]==["job_a"] and cards[0]["title"]=="Edited title";
    reset_cache();
    # Before the first warm-up, saved cards are served unless they have expired.
    cold=catalog._current_cards([row("job_a"),row("job_c",expires_at=time.time()-10)],26);
    assert [c["id"] for c in cold]==["job_a"];
}
