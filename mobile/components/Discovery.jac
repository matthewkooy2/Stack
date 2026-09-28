import from "@jac/mobui" { View, Text, Pressable, ScrollView, Modal, ActivityIndicator }
import from "../device.js" { rpc, errorText, Icon, SwipeSurface, Lifecycle, openJobLink, SourceAttribution }
import from ..theme { s }
import from .UI { Button, Field, Chip, Empty, Logo }
import from .MatchInputs { toggled }

"""Status marks used in match explanations."""
def mark(status: str) -> str {
    return {"match":"✓","unknown":"?","partial":"~","conflict":"✕"}[status];
}
glob OVERRIDE_NAMES: list[dict[str, str]] = [{"key":"roles","label":"role"},{"key":"location","label":"location"},{"key":"modes","label":"work arrangement"},{"key":"employment_types","label":"employment type"},{"key":"salary_min","label":"pay"},{"key":"exclude_companies","label":"hidden employers"},{"key":"exclude_terms","label":"hidden terms"},{"key":"soft","label":"nice-to-haves"}];

def:pub Discovery(decisions: list[dict[str, any]], saved: dict[str, any], profile: dict[str, any], onSwipe: any, disabled: bool) -> JsxElement {
    has jobs: list[dict[str, any]] = [], sources: list[dict[str, any]] = [], occupations: list[str] = [],
        query: str = "", location: str = "", modes: list[str] = [], occupation: str = "Any", levels: list[str] = [], types: list[str] = [], minimum: str = "", period: str = "year", age: str = "Any", order: str = "relevance", datedOnly: bool = False, timelineMode: str = "compatible", confirmedOnly: bool = False, anyRole: bool = False, graduation: str = "", availableFrom: str = "",
        criteria: dict[str, any] = {}, excluded: list[dict[str, any]] = [],
        activeQuery: str = "", activeFilters: dict[str, any] = {}, nextCursor: str = "", loading: bool = False, error: str = "", notice: str = "", sheet: str = "", selectedJob: dict[str, any] = {},
        importUrl: str = "", importId: str = "", hidden: list[str] = [], opening: bool = False, sourceLoading: bool = False, sequence: int = 0, pollCount: int = 0;

    def filters -> dict[str, any] {
        # The server stores only values that differ from the profile, so unchanged fields keep following it.
        return {"country":"US","location":location,"modes":modes,"occupation":occupation,"levels":levels,"employment_types":types,"salary_min":float(minimum) if minimum else 0,"salary_period":period,"posted_days":int(age) if age!="Any" else 0,"sort":order,"has_posting_date":datedOnly,"timeline":timelineMode,"confirmed_only":confirmedOnly,"any_role":anyRole};
    }
    def openFilters -> None {
        # Start from the effective search: profile defaults plus this search's overrides.
        c=criteria;f=activeFilters;
        query="" if f.get("any_role") else c.get("roles","");location=c.get("location","");modes=c.get("modes",[]);types=c.get("employment_types",[]);levels=c.get("levels",[]);
        minimum=str(c["salary_min"]) if c.get("salary_min") else "";period=c.get("salary_period","year");confirmedOnly=bool(c.get("confirmed_only"));timelineMode=c.get("timeline","compatible");
        occupation=f.get("occupation","Any");age=str(f.get("posted_days",0) or "Any");order=f.get("sort","relevance");datedOnly=bool(f.get("has_posting_date"));anyRole=bool(f.get("any_role"));
        sheet="Filters";
    }
    async def load(more: bool = False, queue: bool = False) -> None {
        if loading { return; } loading=True; error=""; sequence+=1; observed=sequence;
        try {
            response=await rpc("search_jobs",{"query":activeQuery,"filters":activeFilters,"cursor":nextCursor if more else "","refresh":queue});
            if observed==sequence {
                jobs=jobs+[j for j in response["jobs"] if j["id"] not in [old["id"] for old in jobs]] if more else response["jobs"];nextCursor=response["next_cursor"];sources=response["sources"];occupations=response["occupations"];graduation=response["timeline_preferences"]["graduation_month"];availableFrom=response["timeline_preferences"]["available_from"];criteria=response["criteria"];excluded=response["excluded"];
                if queue { notice=""; }
            }
        } except Exception as e { error=errorText(e); }
        loading=False;
        if nextCursor and not error and len([j for j in jobs if j["id"] not in hidden and j["id"] not in [d["job_id"] for d in decisions]])<5 { await load(True); }
    }
    async can with entry {
        # Only explicit search overrides are saved; the server merges them with the current profile.
        activeQuery=str(saved.get("query",""));activeFilters=saved.get("filters",{});await load(False,True);
    }
    async def search -> None {
        if loading { return; }
        try {
            stored=await rpc("save_search",{"query":"" if anyRole else query,"filters":filters()});
            activeQuery=stored["query"];activeFilters=stored["filters"];nextCursor="";jobs=[];sheet="";await load(False,True);
        } except Exception as e { error=errorText(e); }
    }
    async def resetSearch -> None {
        if loading { return; }
        try {
            await rpc("reset_search",{});
            activeQuery="";activeFilters={};nextCursor="";jobs=[];sheet="";await load(False,True);
        } except Exception as e { error=errorText(e); }
    }
    async def saveTimeline -> None {
        if loading { return; }
        try {
            await rpc("save_timeline",{"graduation_month":graduation,"available_from":availableFrom});
            nextCursor="";sheet="";await load();
        } except Exception as e { error=errorText(e); }
    }
    async def swipe(action: str, id: str) -> None {
        deck=[j for j in jobs if j["id"] not in hidden and j["id"] not in [d["job_id"] for d in decisions]];
        if disabled or not deck or deck[0]["id"]!=id { return; }
        hidden=hidden+[id];error="";
        try {
            await onSwipe(id,action);
            if nextCursor and not loading and len([j for j in jobs if j["id"] not in hidden and j["id"] not in [d["job_id"] for d in decisions]])<5 { await load(True); }
        } except Exception as e { hidden=[key for key in hidden if key!=id];error="Not saved. "+errorText(e); }
    }
    async def details(id: str) -> None {
        if opening { return; }opening=True;error="";
        try { selectedJob=await rpc("get_job",{"id":id});sheet="Job details"; }
        except Exception as e { error=errorText(e); }
        opening=False;
    }
    async def refresh -> None {
        # The deck remains stable while browsing; collection runs independently.
        if importId {
            try {
                result=await rpc("get_import_status",{"id":importId});notice="Import: "+result["status"]+". "+result.get("message","");
                if result["status"] in ["complete","review","error"] { importId="";await load(); }
            } except Exception as e { error=errorText(e); }
        }
    }
    async def showSources -> None {
        sheet="Sources";sourceLoading=True;error="";
        try { response=await rpc("source_status",{});sources=response["sources"]; }
        except Exception as e { error=errorText(e); }
        sourceLoading=False;
    }
    async def importLink -> None {
        try { result=await rpc("import_job_url",{"url":importUrl});importId=result["id"];notice="Link queued for verification. It will appear only if a supported, active US job is found.";sheet=""; }
        except Exception as e { error=errorText(e); }
    }
    async def openLink(url: str) -> None {
        try { await openJobLink(url); } except Exception as e { error=errorText(e); }
    }
    <View style={{gap:14}}>
        <Lifecycle onRefresh={refresh} onOpen={lambda (data: any) { }}/>
        <View style={s.between}><View style={{gap:6}}><Text style={s.title}>Jobs</Text></View><Pressable accessibilityLabel="Filter jobs" style={s.iconButton} onPress={openFilters}><Icon name="filter" size={21}/></Pressable></View>
        <ScrollView horizontal={True} showsHorizontalScrollIndicator={False} contentContainerStyle={{gap:8}}><Chip label={criteria.get("roles","") or "All professions"} active={True} onPress={openFilters}/><Chip label={"Sort: "+("Newest first" if activeFilters.get("sort","relevance")=="newest" else "Best match")} onPress={openFilters}/><Chip label={"Graduation: "+graduation if graduation else "Set graduation timeline"} onPress={lambda { sheet="Your timeline"; }}/><Chip label="Live sources" onPress={showSources}/></ScrollView>
        {<Text style={s.errorText}>{error}</Text> if error else None}
        {<Text style={s.small}>{notice}</Text> if notice else None}
        {[<Text key={n} style={s.errorText}>{n}</Text> for n in criteria.get("notices",[])]}
        {<View style={s.between}><Text style={[s.small,{flex:1}]}>{"This search changes your profile’s "+", ".join([o["label"] for o in OVERRIDE_NAMES if criteria["sources"].get(o["key"])=="search"])+"."}</Text><Pressable accessibilityRole="button" accessibilityLabel="Use profile settings" onPress={resetSearch}><Text style={[s.small,{color:"#3765E8",fontWeight:"700"}]}>Use profile</Text></Pressable></View> if criteria.get("sources") and len([o for o in OVERRIDE_NAMES if criteria["sources"].get(o["key"])=="search"])>0 else None}
        {<ActivityIndicator color="#3765E8"/> if loading and not jobs else None}
        {[(
            <View key={job["id"]} style={{gap:19}}>
                <SwipeSurface cardId={job["id"]} disabled={disabled} onSwipe={lambda (action: str) { return swipe(action,job["id"]); }}>
                    <View style={s.jobCard}>
                        <View style={s.jobTop}>
                            <View style={s.between}><Logo job={job}/><Text style={s.small}>{job["posted"]}</Text></View>
                            <View style={{gap:6}}><Text style={s.strong}>{job["company"]}</Text><Text style={[s.jobTitle,{fontSize:24,lineHeight:29}]}>{job["title"]}</Text><Text style={s.small}>{job["location"]+(" · "+job["mode"] if job["mode"]!="Unknown" else "")}</Text></View>
                            <Button label="Open job" icon="next" onPress={lambda { openLink(str(job.get("listing_url",job["url"]))); }}/>
                            {<Text style={[s.strong,{color:"#167867"}]}>{job["salary"]}</Text> if job["salary"]!="Pay not listed" else (<Text style={s.small} numberOfLines={2}>{job["highlights"]["pay_excerpt"]}</Text> if job["highlights"]["pay_excerpt"] else None)}
                            <View style={s.wrap}>{[<Chip key={tag} label={tag}/> for tag in job["tags"]]}</View>
                            <View style={{gap:6}}><Text style={s.label}>THE ROLE</Text>{[<Text key={line} style={s.body} numberOfLines={3}>{line}</Text> for line in job["highlights"]["responsibilities"][:1]]}{<Text style={s.small}>Description unavailable from this source. Open the job for details.</Text> if not job["highlights"]["responsibilities"] else None}</View>
                            {<View style={{gap:6}}><Text style={s.label}>WHAT THEY’RE LOOKING FOR</Text>{[<Text key={line} style={s.small} numberOfLines={3}>{"• "+line}</Text> for line in job["highlights"]["requirements"]]}</View> if job["highlights"]["requirements"] else None}
                            <SourceAttribution job={job}/>
                        </View>
                        <View style={[s.jobBottom,{padding:16,gap:8}]}><Text style={s.strong}>{job["match"]["label"]}</Text>{[<Text key={"r"+r} style={s.small} numberOfLines={2}>{"✓ "+r}</Text> for r in job["match"]["reasons"]]}{[<Text key={"u"+u} style={s.small} numberOfLines={2}>{"? "+u}</Text> for u in job["match"]["uncertain"][:3]]}{[<Text key={"c"+c} style={s.small} numberOfLines={2}>{"~ "+c}</Text> for c in job["match"]["caveats"][:2]]}<Button label={"Loading details…" if opening else "Full details"} secondary={True} disabled={opening} onPress={lambda { details(job["id"]); }}/></View>
                    </View>
                </SwipeSurface>
                <View style={s.row}><View style={{flex:1}}><Button label="Pass" icon="x" onPress={lambda { swipe("pass",job["id"]); }} secondary={True} disabled={disabled}/></View><View style={{flex:1.6}}><Button label="Ready to apply" icon="bookmark" onPress={lambda { swipe("apply",job["id"]); }} disabled={disabled}/></View></View>
                <Text style={[s.small,{textAlign:"center"}]}>Swipe left to pass. Right to save to Applications.{"\n"}Complete the application on the employer’s site.</Text>
            </View>
        ) for job in [j for j in jobs if j["id"] not in hidden and j["id"] not in [d["job_id"] for d in decisions]][:1]]}
        {<Empty title={"No confirmed timeline matches." if activeFilters.get("timeline")=="confirmed" else "No more matches here."} text={"Many listings lack a clear graduation window. Add your graduation date, or choose Hide timeline mismatches to include unclear listings." if activeFilters.get("timeline")=="confirmed" else ("Hidden by your requirements: "+", ".join([x["reason"]+" ("+str(x["count"])+")" for x in excluded[:4]])+". Mark some as nice to have in Filters or your profile to see them ranked lower." if len(excluded)>0 else "Try another role or location, load more results, or refresh after sources finish collecting.")} icon="search"/> if not loading and len([j for j in jobs if j["id"] not in hidden and j["id"] not in [d["job_id"] for d in decisions]])==0 else None}
        {<Button label="Load more jobs" onPress={lambda { load(True); }} secondary={True} disabled={loading}/> if nextCursor else None}
        <View style={s.wrap}><Button label="Refresh jobs" onPress={lambda { load(False,True); }} secondary={True} disabled={loading}/><Button label="Import a job link" onPress={lambda { sheet="Import a job"; }} secondary={True}/></View>
        <Text style={s.small}>US coverage · Some sources may be unavailable. View Live sources for collection status.</Text>
        <Modal visible={bool(sheet)} presentationStyle="pageSheet" animationType="slide" onRequestClose={lambda { sheet=""; }}>
            <View style={s.screen}><View style={s.modalHeader}><Button label="Close job panel" secondary={True} onPress={lambda { sheet=""; }}/><Text style={s.heading}>{sheet}</Text></View>
            <ScrollView contentContainerStyle={s.content} keyboardShouldPersistTaps="handled">
                {<Text style={s.errorText}>{error}</Text> if error else None}
                {<View style={{gap:18}}>
                    <Field label="Role or job title" value={query} onChange={lambda (v: str) { query=v;anyRole=False; }} placeholder="Nurse, electrician, software engineer…"/>
                    <View style={s.wrap}><Chip label="Search all professions" active={anyRole} onPress={lambda { anyRole=not anyRole; }}/></View><Text style={s.small}>Separate several roles with commas. Related titles must share an O*NET occupation.</Text>
                    <Field label="City or state" value={location} onChange={lambda (v: str) { location=v; }} placeholder="United States"/>
                    <Text style={s.label}>Work arrangement</Text><View style={s.wrap}><Chip label="Any" active={len(modes)==0} onPress={lambda { modes=[]; }}/>{[<Chip key={v} label={v} active={v in modes} onPress={lambda { modes=toggled(modes,v); }}/> for v in ["Remote","Hybrid","On-site"]]}</View>
                    <Text style={s.label}>Occupation</Text><View style={s.wrap}>{[<Chip key={v} label={v} active={occupation==v} onPress={lambda { occupation=v; }}/> for v in ["Any"]+occupations]}</View>
                    <Text style={s.label}>Level</Text><View style={s.wrap}><Chip label="Any level" active={len(levels)==0} onPress={lambda { levels=[]; }}/>{[<Chip key={v} label={v} active={v in levels} onPress={lambda { levels=toggled(levels,v); }}/> for v in ["Internship","Entry-level","Mid-level","Senior","Leadership"]]}</View>
                    <Text style={s.label}>Employment</Text><View style={s.wrap}><Chip label="Any type" active={len(types)==0} onPress={lambda { types=[]; }}/>{[<Chip key={v} label={v} active={v in types} onPress={lambda { types=toggled(types,v); }}/> for v in ["Full-time","Part-time","Contract","Temporary","Internship"]]}</View>
                    <Field label="Minimum advertised pay (USD)" value={minimum} onChange={lambda (v: str) { minimum=v; }}/><View style={s.wrap}>{[<Chip key={v} label={v} active={period==v} onPress={lambda { period=v; }}/> for v in ["hour","year"]]}</View><Text style={s.small}>Hourly and yearly pay are compared at 2,080 hours per year.</Text>
                    <Text style={s.label}>Listings missing details</Text><View style={s.wrap}><Chip label="Show and flag them" active={not confirmedOnly} onPress={lambda { confirmedOnly=False; }}/><Chip label="Confirmed matches only" active={confirmedOnly} onPress={lambda { confirmedOnly=True; }}/></View><Text style={s.small}>A listing that doesn’t state pay, arrangement, or type can’t be confirmed. Flagged jobs rank below confirmed ones.</Text>
                    <Text style={s.label}>Graduation timeline</Text><View style={s.wrap}><Chip label="Hide timeline mismatches" active={timelineMode=="compatible"} onPress={lambda { timelineMode="compatible"; }}/><Chip label="Confirmed timeline matches only" active={timelineMode=="confirmed"} onPress={lambda { timelineMode="confirmed"; }}/><Chip label="All timelines" active={timelineMode=="all"} onPress={lambda { timelineMode="all"; }}/></View><Text style={s.small}>Unclear requirements stay visible unless you select confirmed matches only. Add your graduation month using the timeline button in Jobs.</Text>
                    <Text style={s.label}>Sort jobs</Text><View style={s.wrap}><Chip label="Best match" active={order=="relevance"} onPress={lambda { order="relevance"; }}/><Chip label="Newest first" active={order=="newest"} onPress={lambda { order="newest"; }}/></View>
                    <Text style={s.small}>Best match ranks title fit and confirmed requirements first, then nice-to-haves, then posting date. Newest first puts unknown dates last.</Text>
                    <Text style={s.label}>Posting date</Text><View style={s.wrap}><Chip label="Include unknown dates" active={not datedOnly} onPress={lambda { datedOnly=False; }}/><Chip label="Has posting date" active={datedOnly} onPress={lambda { datedOnly=True; }}/></View>
                    <Text style={s.label}>Posted within days</Text><View style={s.wrap}>{[<Chip key={v} label={v} active={age==v} onPress={lambda { age=v; }}/> for v in ["Any","1","7","30"]]}</View>
                    <Text style={s.small}>These choices apply to this search. Career stage, experience, education, exclusions, and nice-to-haves come from your profile.</Text>
                    <Button label="Show opportunities" onPress={search} disabled={loading}/><Button label="Reset to profile settings" onPress={resetSearch} secondary={True} disabled={loading}/><Text style={s.small}>Title aliases use O*NET 31.0 data · CC BY 4.0 · U.S. Department of Labor.</Text>
                </View> if sheet=="Filters" else None}
                {<View style={{gap:18}}><Field label="Expected graduation (YYYY-MM)" value={graduation} onChange={lambda (v: str) { graduation=v; }} placeholder="2027-05"/><Field label="Available full-time from (YYYY-MM)" value={availableFrom} onChange={lambda (v: str) { availableFrom=v; }} placeholder="Optional"/><Text style={s.small}>Availability applies to full-time roles, not internships. Leave either date blank if it does not apply.</Text><Button label="Save graduation timeline" onPress={saveTimeline}/></View> if sheet=="Your timeline" else None}
                {<ActivityIndicator/> if sourceLoading and sheet=="Sources" else None}
                {<View style={{gap:16}}>{[<View key={source["id"]} style={s.card}><Text style={s.strong}>{source["name"]}</Text><Chip label={source["status"]}/><Text style={s.small}>{source.get("message","")}</Text><Text style={s.small}>{str(source.get("unique_added",0))} new catalog entries</Text></View> for source in sources]}</View> if sheet=="Sources" else None}
                {<View style={{gap:18}}><Field label="Public job URL" value={importUrl} onChange={lambda (v: str) { importUrl=v; }}/><Text style={s.body}>Paste a public employer or job-board link. Unsupported pages will be flagged for review.</Text><Button label="Verify job link" onPress={importLink}/></View> if sheet=="Import a job" else None}
                {<View style={{gap:18}}><Logo job={selectedJob}/><Text style={s.title}>{selectedJob["title"]}</Text><Text style={s.body}>{selectedJob["company"]} · {selectedJob["location"]}</Text><Button label="Open job" onPress={lambda { openLink(str(selectedJob.get("listing_url",selectedJob["url"]))); }}/><Text style={s.strong}>{selectedJob["posted"]}</Text><Text style={s.heading}>{selectedJob.get("match",{}).get("label","")}</Text><Text style={s.label}>HOW THIS MATCHES YOU</Text>{[<Text key={str(i)} style={s.body}>{mark(c["status"])+" "+c["label"]+(" (nice to have)" if not c["required"] else "")+": "+c["detail"]}</Text> for (i,c) in enumerate(selectedJob.get("match",{}).get("checks",[]))]}<Text style={s.small}>✓ confirmed · ? not stated or unclear · ~ fits with a caveat · ✕ conflicts with a nice-to-have</Text>{<View style={{gap:6}}><Text style={s.label}>CONFIRM BEFORE APPLYING</Text>{[<Text key={q} style={s.body}>{"• "+q}</Text> for q in selectedJob["match"]["confirm"]]}</View> if len(selectedJob.get("match",{}).get("confirm",[]))>0 else None}<Text style={s.heading}>{selectedJob["timeline"]["label"]}</Text><Text style={s.body}>{selectedJob["timeline"]["reason"]}</Text><Text style={s.small}>Timeline check only · Not a guarantee of eligibility. Based on the listing text below.</Text>{[<View key={str(i)} style={s.card}><Text style={s.small}>{item["field"]}</Text><Text style={s.body}>{item["quote"]}</Text></View> for (i,item) in enumerate(selectedJob["timeline"]["evidence"])]}<SourceAttribution job={selectedJob}/><Text style={s.small}>{"Description excerpt — read the full listing at the source." if selectedJob["snippet"] else "Employer listing"}</Text><Text style={s.body}>{selectedJob["description"]}</Text><Text style={s.body}>{selectedJob["qualifications"]}</Text><Text style={s.body}>{selectedJob["eligibility"]}</Text><Text style={s.body}>{selectedJob["remote_eligibility"]}</Text><Button label="Open application page" onPress={lambda { openLink(selectedJob["url"]); }}/></View> if sheet=="Job details" and len(selectedJob)>0 else None}
            </ScrollView></View>
        </Modal>
    </View>
}
