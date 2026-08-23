import SwiftUI

struct RemoteDebugView: View {
    @ObservedObject var logger = RemoteDebugLogger.shared
    @State private var filter = ""

    var filtered: [String] {
        guard !filter.isEmpty else { return logger.lines }
        return logger.lines.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Filter\u{2026}", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Button("Clear") { logger.clear() }
                    .buttonStyle(.bordered)
            }
            .padding(8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(filtered.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 1)
                                .background(idx % 2 == 0 ? Color.clear : Color.secondary.opacity(0.05))
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: logger.lines.count) { _ in
                    withAnimation(.none) { proxy.scrollTo("bottom") }
                }
                .onAppear {
                    proxy.scrollTo("bottom")
                }
            }
        }
        .frame(minWidth: 600, minHeight: 350)
    }
}
