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
def fake_usage(key: str) -> catalog.Usage {
    if key not in counters { counters[key]=catalog.Usage(key=key); }
    return counters[key];
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
