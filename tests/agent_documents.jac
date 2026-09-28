"""Exercise actual PDF generation/extraction in Jac's pinned dependency environment."""
import from agents.documents { render_variant, extract }

with entry {
    facts=[{"key":"resume.project","value":"Built C++ & Python services <with tests>."},{"key":"resume.education","value":"BSc Computer Science — 2025"}];
    result=render_variant("Test Candidate","Original order",facts);
    assert result["checks"]["text_preserved"];
    assert "Built C++ & Python services <with tests>." in extract(result["content"]);
    assert result["pages"]==1;
    assert "Tailored" in result["diff"];
    print("PDF generation, XML escaping, extraction, and diff checks passed.");
}
