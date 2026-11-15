import time;
import core.catalog as catalog;

test "reading a SmartRecruiters listing preserves its application and identity" {
    url="https://jobs.smartrecruiters.com/AECOM2/744000149712580-rail-systems-coordinator?oga=true&trid=keep";
    data={"source":"smartrecruiters","url":url,"canonical_url":url,"title":"Rail Systems Coordinator","description":"Full employer description"};
    listing=catalog.CatalogJob(key="existing-id",canonical_url=url,identity=url,data=data);
    view=catalog._job_view(listing);
    assert view["listing_url"]==url.replace("oga=true&", "");
    assert view["url"]==url and view["canonical_url"]==url and view["id"]=="existing-id";
    assert view["description"]==data["description"] and "listing_url" not in listing.data;
    assert catalog._listing_url({"source":"greenhouse","url":url})==url;
    assert catalog._listing_url({"source":"smartrecruiters","url":"https://other.example/job?oga=true"})=="https://other.example/job?oga=true";
    assert catalog._listing_url({"source":"smartrecruiters","url":"https://jobs.smartrecruiters.com/Board/123?x=&oga=true&OGA=false#details"})=="https://jobs.smartrecruiters.com/Board/123?x=#details";
    assert catalog._listing_url({"source":"smartrecruiters","url":"https://jobs.smartrecruiters.com/Board/123"})=="https://jobs.smartrecruiters.com/Board/123";
}

test "a clean sweep closes only listings its sources stopped listing" {
    now=time.time();clean="greenhouse:sweep-lifecycle-clean";failed="lever:sweep-lifecycle-failed";
    run=catalog.SweepRun(key="today",started_at=now,sources={clean:{"status":"ready"},failed:{"status":"error"}});
    def seen(source: str, which: str) -> dict[str, any] { return {source:{"active":True,"run":which,"last_seen":now}}; }
    kept=root.shared ++> catalog.CatalogJob(key="sweep-lifecycle-kept",canonical_url="https://example.com/kept",identity="kept",data={"title":"Kept"},checked_at=now,discovered_at=now,observations=seen(clean,"today"));
    gone=root.shared ++> catalog.CatalogJob(key="sweep-lifecycle-gone",canonical_url="https://example.com/gone",identity="gone",data={"title":"Gone"},checked_at=now,discovered_at=now,observations=seen(clean,"yesterday"));
    held=root.shared ++> catalog.CatalogJob(key="sweep-lifecycle-held",canonical_url="https://example.com/held",identity="held",data={"title":"Held"},checked_at=now,discovered_at=now,observations=seen(failed,"yesterday"));
    both=root.shared ++> catalog.CatalogJob(key="sweep-lifecycle-both",canonical_url="https://example.com/both",identity="both",data={"title":"Both"},checked_at=now,discovered_at=now,observations={**seen(clean,"yesterday"),**seen(failed,"yesterday")});
    assert catalog._deactivate_missing(run)==1;
    assert kept.active and held.active;
    assert not gone.active and not gone.observations[clean]["active"];
    # Another source that failed today still lists it, so it stays open.
    assert both.active and not both.observations[clean]["active"] and both.observations[failed]["active"];
    del kept;del gone;del held;del both;
}
