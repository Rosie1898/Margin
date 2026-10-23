import SwiftUI
import AppKit

@MainActor
private final class ColorControlState: ObservableObject {
    @Published var isPresented = false
    @Published var draft = ""
}

struct AnnotationColorControl: View {
    @Binding var hex: String
    var title: String
    var localize: (String) -> String
    @StateObject private var state = ColorControlState()

    var body: some View {
        Button {
            state.draft = hex
            state.isPresented.toggle()
        } label: {
            RoundedRectangle(cornerRadius:5).fill(Color(hex:hex)).frame(width:23,height:20)
                .overlay(RoundedRectangle(cornerRadius:5).stroke(Color.primary.opacity(0.18)))
                .overlay(Image(systemName:"plus").font(.system(size:9,weight:.semibold)).foregroundStyle(Color(hex:"385A4B")))
                .frame(width:26,height:26).contentShape(Rectangle())
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
            .popover(isPresented:$state.isPresented) {
                VStack(alignment:.leading,spacing:14) {
                    Text(title).font(.system(size:13,weight:.semibold))
                    ColorPicker(localize("颜色选择器"),selection:Binding(get:{Color(hex:hex)},set:{value in let picked=NSColor(value).hex;hex=picked;state.draft=picked}),supportsOpacity:false)
                    HStack {
                        Text("#").foregroundStyle(.secondary)
                        TextField("RRGGBB",text:$state.draft).textFieldStyle(.roundedBorder)
                            .font(.system(size:12,design:.monospaced)).onSubmit(apply)
                            .accessibilityLabel(localize("十六进制颜色"))
                    }
                    Button(localize("应用颜色"),action:apply).buttonStyle(.borderedProminent)
                        .disabled(normalizedHex(state.draft) == nil)
                }.padding(18).frame(width:240)
            }
    }
    private func apply() {
        guard let value=normalizedHex(state.draft) else {return}
        hex=value
        state.isPresented=false
    }
}
