import base64;
import tempfile;
import from pathlib { Path }
import from jaclang.testing.testing { JacTestClient }
import from agents.resume_parser { parse_pdf, validate_values, sections, confirmed_facts }

def rpc(client: any, name: str, args: dict[str, any] = {}) -> dict[str, any] {
    result=client.post("/function/"+name,json=args);assert result.ok,result.text;
    return result.data["result"];
}

test "OpenResume parses the upstream sample matching the requested review" {
    parsed=parse_pdf(Path("tests/fixtures/openresume-laverne.pdf"));values=parsed["values"];
    assert values["profile.name"]=="Leo Leopard";
    assert values["profile.email"]=="lleopard@laverne.edu";
    assert values["educations.0.gpa"]=="3.5";
    assert values["workExperiences.0.company"]=="LionLike MindState, Pomona, CA";
    assert values["workExperiences.1.jobTitle"]=="Volunteer Swim Coach";
    assert "HONORS/AWARDS" in values["additional.descriptions"];
    assert "ON CAMPUS INVOLVEMENT" in values["additional.descriptions"];
    assert len(sections(values))==7;
    with testraises(ValueError) { parse_pdf(Path("tests/fixtures/blank.pdf")); }
}

test "review validation is bounded and preserves grouped provenance" {
    for bad in [{"profile.unknown":"x"},{"workExperiences.20.company":"x"},{"profile.name":3},{"profile.name":"x"*8001}] {
        with testraises(ValueError) { validate_values(bad); }
    }
    values=validate_values({"workExperiences.0.company":" Acme ","workExperiences.0.jobTitle":"Engineer","workExperiences.0.descriptions":"Built services","profile.name":"Candidate"});
    facts=confirmed_facts("test-resume","Candidate.pdf",values);
    assert facts[1]["value"]=="Company: Acme\nJob title: Engineer\nDescriptions: Built services";
    assert all(f["resume_id"]=="test-resume" and f["source"]=="Candidate.pdf" for f in facts);
}

test "resume review persists without implicit confirmation and enforces ownership and revisions" {
    with tempfile.TemporaryDirectory(prefix="stack-resume-review-") as directory {
        client=JacTestClient.from_file(str(Path("main.jac").resolve()),base_path=directory);
        resume_id="";
        try {
            registered=client.register_user("resume-review","Review-password-123");assert registered.ok;
            token=registered.data["token"];
            uploaded=rpc(client,"upload_resume",{"name":"Candidate.pdf","content":base64.b64encode(Path("tests/fixtures/openresume-laverne.pdf").read_bytes()).decode()});
            resume_id=uploaded["resumes"][0]["id"];
            rpc(client,"agent_save_facts",{"facts":[{"key":"resume."+resume_id+".0","resume_id":resume_id,"value":"Legacy extracted line","verified":False},{"key":"name","value":"Separate confirmed profile name","verified":True},{"key":"resume.other.0","resume_id":"other","value":"Different resume","verified":True}]});
            review=rpc(client,"agent_extract_resume",{"id":resume_id});assert not review["confirmed"],review;
            assert len(rpc(client,"agent_settings")["facts"])==3;
            assert rpc(client,"agent_extract_resume",{"id":resume_id})["revision"]==review["revision"];
            values={field["key"]:field["value"] for section in review["sections"] for field in section["fields"]};
            values["profile.name"]="Corrected Candidate";
            draft=rpc(client,"resume_save_details",{"id":resume_id,"revision":review["revision"],"values":values});assert not draft["confirmed"],draft;
            assert "error" in rpc(client,"resume_save_details",{"id":resume_id,"revision":review["revision"],"values":values,"confirm":True});
            resume_facts=[f for f in rpc(client,"agent_settings")["facts"] if f.get("resume_id")==resume_id];assert resume_facts and not any(f["verified"] for f in resume_facts);
            done=rpc(client,"resume_save_details",{"id":resume_id,"revision":draft["revision"],"values":values,"confirm":True});assert done["confirmed"],done;
            facts=rpc(client,"agent_settings")["facts"];
            assert all(f["verified"] for f in facts);
            assert not any(f["value"]=="Legacy extracted line" for f in facts);
            assert any(f["value"]=="Different resume" for f in facts);
            assert any(f["value"]=="Separate confirmed profile name" for f in facts);
            client.reload();client.set_auth_token(token);
            restored=rpc(client,"agent_extract_resume",{"id":resume_id});assert restored["confirmed"];
            assert restored["sections"][0]["fields"][0]["value"]=="Corrected Candidate";
            assert rpc(client,"read_resume",{"id":resume_id})["review"]["confirmed"];
            other=client.register_user("resume-stranger","Review-password-456");assert other.ok;
            assert "error" in rpc(client,"agent_extract_resume",{"id":resume_id});
            assert "error" in rpc(client,"resume_save_details",{"id":resume_id,"revision":restored["revision"],"values":values,"confirm":True});
            client.clear_auth();assert client.post("/function/agent_extract_resume",json={"id":resume_id}).status_code==401;
        } finally {
            if resume_id { client.set_auth_token(token);rpc(client,"change_resume",{"id":resume_id,"action":"delete"}); }
            client.close();
        }
    }
}
