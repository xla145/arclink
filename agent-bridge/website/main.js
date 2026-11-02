// Native details elements work without JavaScript. Keep the FAQ concise when enhanced.
const questions = document.querySelectorAll(".faq details");
for (const question of questions) {
  question.addEventListener("toggle", () => {
    if (!question.open) return;
    for (const other of questions) {
      if (other !== question) other.open = false;
    }
  });
}
