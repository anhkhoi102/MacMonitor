import SwiftUI

/// Command-Line-Tools workaround – read this if you are curious!
///
/// In the macOS 27 SDK, `@State` is declared twice: as the classic property
/// wrapper *and* as a Swift macro. When both exist the compiler picks the
/// macro, whose implementation (`SwiftUIMacros` plugin) ships only with full
/// Xcode. With just the Command Line Tools that fails with:
///   "plugin for module 'SwiftUIMacros' not found"
///
/// A typealias has no macro attached, so `@ViewState` always resolves to the
/// plain property wrapper. It behaves exactly like `@State`.
/// Use `@ViewState` everywhere you would normally write `@State`.
typealias ViewState<Value> = SwiftUI.State<Value>
