import time;
import core.catalog as catalog;
import from unittest.mock { patch }

test "reading a SmartRecruiters listing preserves its application and identity" {
    url="https://jobs.smartrecruiters.com/AECOM2/744000149712580-rail-systems-coordinator?oga=true&trid=keep";
    data={"source":"smartrecruiters","url":url,"canonical_url":url,"title":"Rail Systems Coordinator","description":"Full employer description"};
    listing=catalog.CatalogJob(key="existing-id",canonical_url=url,identity=url,data=data);
    view=catalog._job_view(listing);
    assert view["listing_url"]==url.replace("oga=true&", "");
    assert view["url"]==url and view["canonical_url"]==url and view["id"]=="existing-id";
    assert view["description"]==data["description"] and "listing_url" not in listing.data;
    assert catalog._listing_url({"source":"adzuna","url":url})==url;
    assert catalog._listing_url({"source":"smartrecruiters","url":"https://other.example/job?oga=true"})=="https://other.example/job?oga=true";
    assert catalog._listing_url({"source":"smartrecruiters","url":"https://jobs.smartrecruiters.com/Board/123?x=&oga=true&OGA=false#details"})=="https://jobs.smartrecruiters.com/Board/123?x=#details";
    assert catalog._listing_url({"source":"smartrecruiters","url":"https://jobs.smartrecruiters.com/Board/123"})=="https://jobs.smartrecruiters.com/Board/123";
}

glob counters: dict[str, catalog.Usage] = {};

test "duplicate source keys complete the exact claimed lease" {
    sid="greenhouse:duplicate-lease-fixture";
    config={"adapter":"greenhouse","name":"Duplicate lease fixture"};
    first=root.shared ++> catalog.JobSource(key=sid,config=config,lease="unrelated",status="collecting");
    claimed=root.shared ++> catalog.JobSource(key=sid,config=config,lease="claimed",status="collecting");
    with patch.object(catalog,"_worker_allowed",return_value=True),patch.object(catalog,"_fresh",return_value=None),patch.object(catalog,"commit",return_value=None) {
        result=catalog.discovery_complete("fixture",sid,"claimed",{"complete":True});
        assert result.get("saved") is True;
        assert claimed.lease=="" and claimed.status=="ready" and claimed.last_success>0;
        assert first.lease=="unrelated" and first.last_success==0;
        assert catalog.discovery_complete("fixture",sid,"claimed",{}).get("error")=="Lease expired or already completed.";
        claimed.lease="unrelated";
        assert catalog.discovery_complete("fixture",sid,"unrelated",{}).get("error")=="Lease expired or already completed.";
        assert first.lease=="unrelated" and claimed.lease=="unrelated";
        assert catalog.discovery_complete("fixture",sid,"",{}).get("error")=="Lease expired or already completed.";
    }
    del first;del claimed;
}
def fake_usage(key: str) -> catalog.Usage {
    if key not in counters { counters[key]=catalog.Usage(key=key); }
    return counters[key];
}

test "municipal absence removal waits for two clean cycles and a day" {
    now=time.time();sid="smartrecruiters:municipal-lifecycle-test";
    source=root.shared ++> catalog.JobSource(key=sid,config={"adapter":"smartrecruiters","name":"Municipal lifecycle fixture"},lease="one",cycle="one");
    listing=root.shared ++> catalog.CatalogJob(key="municipal-lifecycle-job",canonical_url="https://example.com/lifecycle",identity="lifecycle",data={"title":"Municipal fixture"},checked_at=now,discovered_at=now);
    listing.observations={sid:{"active":True,"last_seen":now-86399,"missing":0}};
    with patch.object(catalog,"_worker_allowed",return_value=True),patch.object(catalog,"_fresh",return_value=None),patch.object(catalog,"commit",return_value=None) {
        catalog.discovery_complete("fixture",sid,"one",{"complete":True});
        assert listing.active and listing.observations[sid]["missing"]==1;
        source.lease="two";source.cycle="two";
        catalog.discovery_complete("fixture",sid,"two",{"complete":True});
        assert listing.active and listing.observations[sid]["missing"]==2;
        listing.observations[sid]["last_seen"]=now-86401;
        source.lease="invalid";source.cycle="invalid";
        catalog.discovery_complete("fixture",sid,"invalid",{"complete":True,"invalid":1});
        assert listing.active and listing.observations[sid]["missing"]==2;
        source.lease="three";source.cycle="three";source.cycle_invalid=0;
        catalog.discovery_complete("fixture",sid,"three",{"complete":True});
        assert not listing.active and not listing.observations[sid]["active"];
        listing.observations["independent"]={"active":True,"last_seen":now};
        source.lease="four";source.cycle="four";
        catalog.discovery_complete("fixture",sid,"four",{"complete":True});
        assert listing.active;
    }
    del listing;del source;
}
test "provider budgets reject requests at every boundary" {
    with patch.object(catalog,"_usage",side_effect=fake_usage) {
        counters.clear();
        assert catalog._reserve("theirstack")==25;
        assert catalog._reserve("theirstack")==25;
        assert catalog._reserve("theirstack")==0;
        counters.clear();
        month=time.strftime("%Y-%m",time.gmtime());
        fake_usage("theirstack"+month).amount=1499;
        assert catalog._reserve("theirstack")==1;
        assert catalog._reserve("theirstack")==0;
        counters.clear();
        for i in range(25) { assert catalog._reserve("adzuna")==1; }
        assert catalog._reserve("adzuna")==0;
        for (suffix,limit) in [(time.strftime("%Y-%m-%d",time.gmtime()),250),(time.strftime("%G-%V",time.gmtime()),1000),(month,2500)] {
            counters.clear();fake_usage("adzuna"+suffix).amount=limit-1;
            assert catalog._reserve("adzuna")==1;
            assert catalog._reserve("adzuna")==0;
        }
    }
}
