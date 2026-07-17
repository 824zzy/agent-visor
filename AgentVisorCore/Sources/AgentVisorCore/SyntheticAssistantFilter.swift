import Foundation

/// Predicate for dropping claude-code synthetic-model assistant messages
/// from chat-item rendering.
///
/// claude-code injects synthetic assistant messages to keep the API
/// conversation alternating user/assistant after an interrupted turn or
/// a rate-limit hit. The canonical example is
/// `HD({content: "No response requested."})` in its interrupt handler,
/// which the JSONL persists as:
///
/// ```json
/// {
///   "type": "assistant",
///   "message": {
///     "model": "<synthetic>",
///     "content": [{ "type": "text", "text": "No response requested." }],
///     "usage": { "input_tokens": 0, "output_tokens": 0, ... }
///   }
/// }
/// ```
///
/// These rows are padding for the next API call, not user-facing content.
/// Other downstream consumers (token math, the model chip in the status
/// bar) already filter the same `<`-prefix; this exposes the predicate
/// so the JSONL parser and the on-disk parse-cache loader can agree.
///
/// The predicate uses the `<` prefix rather than an exact match on
/// `"<synthetic>"` so any future bracketed-sentinel variant claude-code
/// invents (e.g. a hypothetical `<rate_limit>`) is also dropped without
/// a code change. Real model ids never start with `<`.
public enum SyntheticAssistantFilter {

    /// Returns true when the message should be skipped.
    ///
    /// - Parameter role: The message role, as the JSONL `type` field or
    ///   `ChatRole.rawValue` ("assistant", "user", "system"). Only
    ///   "assistant" rows can be synthetic — user-typed text and system
    ///   markers pass through regardless of the model field.
    /// - Parameter model: The `message.model` value, or nil if the
    ///   JSONL row didn't carry one (which itself means "not synthetic"
    ///   since claude-code always stamps `<synthetic>` on these).
    public static func shouldDrop(role: String, model: String?) -> Bool {
        guard role == "assistant", let model = model else { return false }
        return model.hasPrefix("<")
    }
}
