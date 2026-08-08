import PDFKit
import SwiftUI

struct CourseOutlineViewerView: View {
    let outline: CourseOutline

    @Environment(\.dismiss) private var dismiss
    @State private var document: PDFDocument?
    @State private var errorMessage: String?
    @State private var loadAttempt = 0

    var body: some View {
        NavigationStack {
            Group {
                if let document {
                    CoursePDFView(document: document)
                        .ignoresSafeArea(edges: .bottom)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label(
                            L10n.tr("Unable to open PDF", "无法打开 PDF"),
                            systemImage: "doc.badge.exclamationmark"
                        )
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button(L10n.tr("Retry", "重试")) {
                            loadAttempt += 1
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(L10n.tr("Loading PDF...", "正在加载 PDF..."))
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(outline.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.tr("Close", "关闭")) {
                        dismiss()
                    }
                }
            }
            .task(id: loadAttempt) {
                await loadDocument()
            }
        }
    }

    @MainActor
    private func loadDocument() async {
        document = nil
        errorMessage = nil

        do {
            let data = try await CourseOutlineService.shared.downloadPDF(for: outline)
            guard let loadedDocument = PDFDocument(data: data),
                  loadedDocument.pageCount > 0 else {
                throw CourseOutlineServiceError.invalidPDF
            }
            document = loadedDocument
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CoursePDFView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
    }
}
