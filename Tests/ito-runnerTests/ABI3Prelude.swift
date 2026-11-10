import Foundation

/// The exports every ABI 3 plugin has, for the WebAssembly test modules in this suite: its ABI
/// (`ito_abi_version`), the kinds it serves (`ito_supported_kinds`, a mask by `MediaKind.wireValue`:
/// manga by default) and its error-report version (`ito_error_version`). A module that leaves
/// them out is refused before it is instantiated.
func abi3Prelude(kinds: Int = 0b001, errorVersion: Int = 2) -> String {
    """
    (func (export "ito_abi_version") (result i32) i32.const 3)
    (func (export "ito_supported_kinds") (result i32) i32.const \(kinds))
    (func (export "ito_error_version") (result i32) i32.const \(errorVersion))
    """
}
