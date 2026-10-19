import Foundation

/// The user-editable instructions that shape `summary.md`.
///
/// Kept apart from `Summarizer` so the settings schema can show the exact
/// instructions that an untouched installation sends to a model. The default
/// is a real field value in the window rather than a shortened example: a
/// person editing a template needs a useful starting point, not a blank page.
enum SummaryTemplate {
    static let `default` = """
    Below is a meeting transcript with speaker labels.

    Write a Markdown note with exactly this structure:

    ## What this was about
    Two or three sentences: the topic and why they met.

    ## Key points
    5–10 substantive bullets. Each one a complete thought, not a fragment.

    ## Decisions
    What was decided. If nothing was, say that plainly.

    ## Action items
    Lines of "— who: what to do (deadline, if one was named)". If there are none, say so.

    ## Open questions
    What was left unresolved. Skip the section entirely if there's nothing.

    No preamble, no "here's your note" — start with the Markdown.
    """
}
