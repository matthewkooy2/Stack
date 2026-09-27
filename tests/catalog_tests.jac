import time;
import core.catalog as catalog;
import from unittest.mock { patch }

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
