import SwiftUI

struct PlaceholderTabView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 18) {
                Image(systemName: systemImage)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 78, height: 78)
                    .glassSurface(cornerRadius: 24)

                Text(title)
                    .font(.largeTitle.bold())

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            .padding(28)
        }
        .navigationTitle(title)
    }
}

struct PlaceholderDetailView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 72, height: 72)
                    .glassSurface(cornerRadius: 22)

                Text(title.displayTitle)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)

                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 310)
            }
            .padding(28)
        }
        .navigationTitle(title.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}
