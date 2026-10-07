import from "./transport.js" { rpc, errorText }

def:pub BulletBank -> JsxElement {
    has data: dict[str, any] = {}, busy: bool = False, error: str = "", notice: str = "",
        id: str = "", revision: int = 0, name: str = "", source: str = "", text: str = "",
        target: str = "", selection: list[dict[str, any]] = [];
    async def load -> None {
        try { data=await rpc("resume_bank",{}); } except Exception as e { error=errorText(e); }
    }
    can with entry { load(); }
    def edit(item: dict[str, any]) -> None {
        id=item["id"];revision=item["revision"];name=item["name"];source=item["source"];
        text="\n".join(r["text"] for r in item["records"]);notice="";
    }
    def clear -> None { id="";revision=0;name="";source="";text=""; }
    async def save(confirm: bool) -> None {
        busy=True;error="";notice="";
        try {
            lines=[line.strip() for line in text.split("\n") if line.strip()];
            data=await rpc("resume_bank_save",{"id":id,"revision":revision,"name":name,"source":source,
                "records":[{"id":"r"+str(i),"kind":"bullet","text":line} for (i,line) in enumerate(lines)],"confirm":confirm});
            clear();notice="Experience confirmed for reuse." if confirm else "Draft saved. Confirm facts before reuse.";
        } except Exception as e { error=errorText(e); }
        busy=False;
    }
    async def remove(item: dict[str, any]) -> None {
        if not window.confirm("Delete this experience and its correction history? Existing selected resumes will need review.") { return; }
        busy=True;error="";
        try { data=await rpc("resume_bank_delete",{"id":item["id"],"revision":item["revision"]});if id==item["id"] { clear(); } }
        except Exception as e { error=errorText(e); }
        busy=False;
    }
    def choose(item: dict[str, any]) -> None { target=item["id"];selection=item["selection"];notice=""; }
    def selected(sid: str, rid: str) -> bool { return any(s["id"]==sid and rid in s["record_ids"] for s in selection); }
    def toggle(item: dict[str, any], rid: str) -> None {
        current=[s for s in selection if s["id"]==item["id"]];
        ids=current[0]["record_ids"] if current else [];
        ids=[x for x in ids if x!=rid] if rid in ids else ids+[rid];
        selection=[s for s in selection if s["id"]!=item["id"]];
        if ids { selection=selection+[{"id":item["id"],"revision":item["revision"],"record_ids":ids}]; }
    }
    async def apply -> None {
        busy=True;error="";notice="";
        try {
            resumes=[r for r in data.get("resumes",[]) if r["id"]==target];
            if not resumes { error="Reload and choose a resume.";busy=False;return; }
            data=await rpc("resume_bank_select",{"id":target,"revision":resumes[0]["revision"],"selection":selection});
            notice="Selected facts will be included in the next tailoring review. Review the complete generated resume before approving.";
        } except Exception as e { error=errorText(e); }
        busy=False;
    }
    <section><h2>Resume bullet bank</h2><p>Keep experience beyond your current resume. Only facts you confirm can be reused. Include the role, employer and dates in each experience name so its bullets keep their context.</p>
        {<p role="alert">{error}</p> if error else <span/>}{<p role="status">{notice}</p> if notice else <span/>}
        <button disabled={busy} onClick={load}>Reload bank</button>
        <article><h3>{"Edit experience" if id else "Add experience"}</h3>
            <label>Experience name<input value={name} onChange={lambda (e: any) { name=e.target.value; }}/></label>
            <label>Source of these facts<input value={source} placeholder="My project notes, 2024" onChange={lambda (e: any) { source=e.target.value; }}/></label>
            <label>Facts, one bullet per line<textarea value={text} onChange={lambda (e: any) { text=e.target.value; }}/></label>
            <p>Confirm only what is accurate. Saving a draft withdraws confirmation. Corrections retain the original source and history.</p>
            <button disabled={busy} onClick={lambda { save(False); }}>Save draft</button><button disabled={busy} onClick={lambda { save(True); }}>Save and confirm facts</button><button disabled={busy} onClick={clear}>New experience</button>
        </article>
        <article><h3>Choose experience for tailoring</h3><p>Choose a confirmed PDF/DOCX resume, then select relevant facts. Imported resume headings and other context lines stay in their original order to preserve roles, dates and credentials. LaTeX resumes continue using their existing source. Manage and confirm imported resume details in the iPhone app.</p>
            {[<button key={r["id"]} disabled={busy or not r["confirmed"]} className={"active" if target==r["id"] else ""} onClick={lambda { choose(r); }}>{r["name"]}</button> for r in data.get("resumes",[])]}
            <button disabled={busy or not target} onClick={apply}>Save selected experience</button>
            <button disabled={busy or not target} onClick={lambda { selection=[];notice="Selection cleared locally. Save selected experience to apply."; }}>Clear selected experience</button>
            {[<p key={item["id"]}>{"Selected source "+item["id"]+" ("+str(len(item["record_ids"]))+" facts)"}<button disabled={busy} onClick={lambda { selection=[x for x in selection if x["id"]!=item["id"]]; }}>Remove selected source</button></p> for item in selection]}
        </article>
        {[<article key={item["id"]}><h3>{item["name"]}</h3><p>{item["source"]+" · "+("Confirmed" if item["confirmed"] else "Draft")}</p>
            {[<label key={r["id"]}><input type="checkbox" checked={selected(item["id"],r["id"])} disabled={busy or not target or target==item["id"] or not item["confirmed"]} onChange={lambda { toggle(item,r["id"]); }}/>{r["text"]}</label> for r in item["records"]]}
            {<div><button disabled={busy} onClick={lambda { edit(item); }}>Edit experience</button><button disabled={busy} onClick={lambda { remove(item); }}>Delete experience</button>
                <details><summary>Sources and corrections</summary>{[<p key={str(h["revision"])}>{"Revision "+str(h["revision"])+" · "+h["source"]+" · "+("Confirmed" if h["confirmed"] else "Draft")+" · "+"; ".join(r["text"] for r in h["records"])}</p> for h in item["history"]]}</details></div> if item["editable"] else <p>Imported resume records; edit them on the Resume tab.</p>}
        </article> for item in data.get("sources",[])]}
    </section>
}
