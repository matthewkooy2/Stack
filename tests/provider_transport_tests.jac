"""Exercise provider routing through the real HTTP allowlist without network calls."""
import json;
import os;
import urllib.request;
import from unittest.mock { patch }
import from agents.contracts { config }
import from agents.provider { generate }
import from agents.security { http }

test "Meta structured results pass the fixed provider allowlist" {
    c = {**config(), "provider": "meta", "model": "muse-test"};
    artifact = {"summary": "Synthetic fit", "strengths": [], "gaps": [], "unknowns": [], "evidence": []};
    response = {"choices": [{"finish_reason": "stop", "message": {"content": json.dumps(artifact)}}], "id": "meta-smoke"};
    with patch.dict(os.environ, {"MODEL_API_KEY": "synthetic-key"}), patch.object(urllib.request, "build_opener") as opener {
        opener.return_value.open.return_value.__enter__.return_value.read.return_value = json.dumps(response).encode();
        result = generate("fit", {}, c);
        assert result["artifact"] == artifact;
        request = opener.return_value.open.call_args.args[0];
        assert request.full_url == "https://api.meta.ai/v1/chat/completions";
        assert request.get_header("Authorization") == "Bearer synthetic-key";
        assert json.loads(request.data)["response_format"]["type"] == "json_schema";
    }
}

test "Adding Meta does not admit insecure or lookalike destinations" {
    with patch.object(urllib.request, "build_opener") as opener {
        for url in ["http://api.meta.ai/v1/chat/completions", "https://api.meta.ai.example.com/v1/chat/completions", "https://example.com"] {
            with testraises(ValueError, `match="Provider destination is not allowed") { http(url); }
        }
        opener.assert_not_called();
    }
}
