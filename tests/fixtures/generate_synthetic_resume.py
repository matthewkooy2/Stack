"""Generate Stack's original fictional upload fixture. No third-party resume content."""
from pathlib import Path
from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import letter

def build(path):
    pdf = canvas.Canvas(str(path), pagesize=letter, invariant=1)
    pdf.setTitle("Stack fictional resume test fixture")
    pdf.setAuthor("Stack test suite")
    text = pdf.beginText(54, 738)
    text.setFont("Helvetica", 11)
    for line in ["Alex Example", "alex@example.invalid | Example City",
                 "EDUCATION", "Example University - BS Computer Science, 2025",
                 "EXPERIENCE", "Example Studio - Software Developer, 2025",
                 "Built a fictional scheduling application for a class project.",
                 "SKILLS", "Python, TypeScript, automated testing"]:
        text.textLine(line)
    pdf.drawText(text)
    pdf.showPage()
    pdf.save()

if __name__ == "__main__":
    build(Path(__file__).with_name("synthetic-resume.pdf"))
