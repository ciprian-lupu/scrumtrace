import Foundation

/// Canonical evaluation schema (standard JSON Schema types).
/// OpenAI Structured Outputs additionally marks every object
/// `additionalProperties: false` and lists every key in `required`.
enum EvaluationJSONSchema {
    static let canonical: [String: Any] = [
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "additionalProperties": false,
        "required": ["candidates"],
        "properties": [
            "candidates": [
                "type": "array",
                "items": candidate
            ]
        ]
    ]

    static let openaiStructured: [String: Any] = [
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "additionalProperties": false,
        "required": ["candidates"],
        "properties": [
            "candidates": [
                "type": "array",
                "items": openaiCandidate
            ]
        ]
    ]

    private static let quote: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["speaker", "text", "t_media_start", "t_media_end"],
        "properties": [
            "speaker": ["type": "string"],
            "text": ["type": "string"],
            "t_media_start": ["type": "number"],
            "t_media_end": ["type": "number"]
        ]
    ]

    private static let candidate: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": [
            "decision", "confidence", "kind", "title",
            "observed", "stated", "inferred",
            "agent_instructions_draft", "frame_references"
        ],
        "properties": [
            "decision": ["type": "string", "enum": ["keep", "needs_review", "drop"]],
            "confidence": ["type": "number"],
            "kind": [
                "type": "string",
                "enum": ["bug", "decision", "action_item", "architecture_note", "improvement"]
            ],
            "title": ["type": "string"],
            "observed": ["type": "string"],
            "stated": ["type": "string"],
            "inferred": ["type": "string"],
            "agent_instructions_draft": ["type": "string"],
            "quotes": [
                "type": "array",
                "items": quote
            ],
            "frame_references": [
                "type": "array",
                "minItems": 1,
                "items": ["type": "string"]
            ]
        ]
    ]

    private static let openaiCandidate: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": [
            "decision", "confidence", "kind", "title",
            "observed", "stated", "inferred",
            "agent_instructions_draft", "quotes", "frame_references"
        ],
        "properties": [
            "decision": ["type": "string", "enum": ["keep", "needs_review", "drop"]],
            "confidence": ["type": "number"],
            "kind": [
                "type": "string",
                "enum": ["bug", "decision", "action_item", "architecture_note", "improvement"]
            ],
            "title": ["type": "string"],
            "observed": ["type": "string"],
            "stated": ["type": "string"],
            "inferred": ["type": "string"],
            "agent_instructions_draft": ["type": "string"],
            "quotes": [
                "type": "array",
                "items": quote
            ],
            "frame_references": [
                "type": "array",
                "minItems": 1,
                "items": ["type": "string"]
            ]
        ]
    ]
}
