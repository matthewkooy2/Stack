"""PDF limits through authenticated API calls; no production service."""
import base64;
import io;
import os;
import tempfile;
import from pathlib { Path }
import from unittest.mock { patch }
import from jaclang.testing.testing { JacTestClient }
import from pypdf { PdfWriter }

def pdf_input(pages: int, encrypted: bool = False) -> bytes {
    writer=PdfWriter();
    for i in range(pages) { writer.add_blank_page(width=612,height=792); }
    if encrypted { writer.encrypt("synthetic-password"); }
    output=io.BytesIO();writer.write(output);return output.getvalue();
}

test "unsafe uploads do not create resume records or files" {
    scratch=Path(".jac/pdf-security-tests");scratch.mkdir(parents=True,exist_ok=True);
    with tempfile.TemporaryDirectory(dir=scratch) as directory {
        settings=Path(directory)/"config.json";settings.write_text('{"invite_only":false}');
        with patch.dict(os.environ,{"STACK_AGENT_CONFIG":str(settings.resolve())}) {
            client=JacTestClient.from_file("main.jac",base_path=directory);
            try {
                registered=client.register_user("pdf-security-owner","Pdf-security-password-123");
                assert registered.ok, registered.text;
                before=client.post("/function/bootstrap",json={}).data["result"];
                owner=before["user_id"];
                import hashlib;
                storage=Path("storage/resumes")/hashlib.sha256(owner.encode()).hexdigest();
                for raw in [b"%PDF-1.4\nmalformed",pdf_input(0),pdf_input(51),pdf_input(1,True)] {
                    response=client.post("/function/upload_resume",json={"name":"Rejected.pdf","content":base64.b64encode(raw).decode()});
                    assert response.ok, response.text;
                    assert "error" in response.data["result"], response.data;
                    assert client.post("/function/bootstrap",json={}).data["result"]["resumes"]==[];
                    assert not storage.exists() or not list(storage.iterdir());
                }
            } finally { client.close(); }
        }
    }
}

test "safe uploads preserve idempotency previews and owner isolation" {
    scratch=Path(".jac/pdf-security-tests");scratch.mkdir(parents=True,exist_ok=True);
    with tempfile.TemporaryDirectory(dir=scratch) as directory {
        settings=Path(directory)/"config.json";settings.write_text('{"invite_only":false}');
        with patch.dict(os.environ,{"STACK_AGENT_CONFIG":str(settings.resolve())}) {
            client=JacTestClient.from_file("main.jac",base_path=directory);
            id="";token="";
            try {
                registered=client.register_user("safe-pdf-owner","Pdf-security-password-123");
                assert registered.ok, registered.text;token=registered.data["token"];
                raw=Path("tests/fixtures/synthetic-resume.pdf").read_bytes();
                args={"name":"Original.pdf","content":base64.b64encode(raw).decode()};
                state=client.post("/function/upload_resume",json=args).data["result"];
                assert len(state["resumes"])==1, state;id=state["resumes"][0]["id"];
                repeated=client.post("/function/upload_resume",json=args).data["result"];
                assert len(repeated["resumes"])==1 and repeated["resumes"][0]["id"]==id;
                preview=client.post("/function/read_resume",json={"id":id}).data["result"];
                assert base64.b64decode(preview["content"])==raw;
                other=client.register_user("other-pdf-owner","Pdf-security-password-456");
                assert other.ok, other.text;
                assert "error" in client.post("/function/read_resume",json={"id":id}).data["result"];
                assert client.post("/function/bootstrap",json={}).data["result"]["resumes"]==[];
            } finally {
                if id and token { client.set_auth_token(token);client.post("/function/change_resume",json={"id":id,"action":"delete"}); }
                client.close();
            }
        }
    }
}
