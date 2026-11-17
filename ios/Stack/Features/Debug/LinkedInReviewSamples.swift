#if DEBUG
import Foundation

/// A LinkedIn PDF review in the exact shape `agents/linkedin.jac` stores (`artifacts.linkedin_review`).
/// Synthetic: replace with a real reply, names changed, once one exists from the configured model.
enum LinkedInReviewSample {
    static let review: JSON = [
        "source": "pdf",
        "summary": "A clear analyst profile that undersells its results. Lead with what your dashboards changed.",
        "strengths": ["Concrete tools and a dashboard project.", "Recent, relevant internship."],
        "findings": [
            ["section": "headline", "priority": "high", "quote": "Data Analyst @ Example Corp",
             "weakness": "Your headline leads with an internship title.",
             "why_it_matters": "It is the first line a recruiter reads in search results.",
             "recommendation": "Lead with the analysis you do and the tools you use."],
            ["section": "experience", "priority": "medium", "quote": "Helped with research projects.",
             "weakness": "The research role is vague.",
             "why_it_matters": "Recruiters skim for outcomes, not duties.",
             "recommendation": "Name one project and what it produced."],
        ],
        "rewrites": [
            ["section": "headline", "text": "Data analyst | SQL, Python and Tableau dashboards", "reason": "Leads with skills."],
        ],
        "questions": ["How many people used the revenue dashboard each week?"],
        "limitations": "Reviewed from your LinkedIn PDF export. The export leaves out your photo, banner, Featured section, recommendations and activity.",
    ]
}
#endif
