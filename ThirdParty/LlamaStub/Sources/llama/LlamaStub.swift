import Foundation

public typealias llama_model = OpaquePointer
public typealias llama_context = OpaquePointer
public typealias llama_batch = OpaquePointer

public struct llama_model_params {
    public init() {}
}

public struct llama_context_params {
    public var n_ctx: Int32 = 0
    public init() {}
}

public func llama_backend_init() {}
public func llama_backend_free() {}

public func llama_model_default_params() -> llama_model_params {
    llama_model_params()
}

public func llama_context_default_params() -> llama_context_params {
    llama_context_params()
}

public func llama_load_model_from_file(_ path: String, _ params: llama_model_params) -> llama_model? {
    nil // stub: returns nil until real binding is provided
}

public func llama_free_model(_ model: llama_model?) {}

public func llama_new_context_with_model(_ model: llama_model?, _ params: llama_context_params) -> llama_context? {
    nil // stub
}

public func llama_free(_ ctx: llama_context?) {}

public func llama_batch_init(_ n_tokens: Int32, _ embd: Int32, _ n_seq_max: Int32) -> llama_batch? {
    nil // stub
}
