import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// User profile settings — name, bio, and profile picture.
struct ProfileSettingsView: View {
    private var prefs: AppPreferences { AppPreferences.shared }

    @State private var name: String = AppPreferences.shared.userName
    @State private var bio: String = AppPreferences.shared.userBio
    @State private var email: String = AppPreferences.shared.userEmail
    @State private var phone: String = AppPreferences.shared.userPhone
    @State private var address: String = AppPreferences.shared.userAddress
    @State private var city: String = AppPreferences.shared.userCity
    @State private var postalCode: String = AppPreferences.shared.userPostalCode
    @State private var country: String = AppPreferences.shared.userCountry
    @State private var assistantNickname: String = AppPreferences.shared.assistantName
    @State private var profileImage: NSImage?

    private static let profileImagePath: String = {
        let dir = NSHomeDirectory() + "/.dockwright"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/profile.png"
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: DockwrightTheme.Spacing.xl) {
                // Profile picture
                profilePictureSection

                // Name
                Section {
                    TextField("Your name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: name) { _, val in prefs.userName = val }
                } header: {
                    sectionHeader("Name")
                }

                // Contact
                Section {
                    TextField("Email", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: email) { _, val in prefs.userEmail = val }
                    TextField("Phone", text: $phone)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: phone) { _, val in prefs.userPhone = val }
                } header: {
                    sectionHeader("Contact")
                }

                // Address
                Section {
                    TextField("Street address", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: address) { _, val in prefs.userAddress = val }
                    HStack(spacing: 8) {
                        TextField("Postal code", text: $postalCode)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                            .onChange(of: postalCode) { _, val in prefs.userPostalCode = val }
                        TextField("City", text: $city)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: city) { _, val in prefs.userCity = val }
                    }
                    TextField("Country", text: $country)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: country) { _, val in prefs.userCountry = val }

                    Text("Used for auto-filling checkout forms when Dockwright shops for you.")
                        .font(DockwrightTheme.Typography.caption)
                        .foregroundStyle(.tertiary)
                } header: {
                    sectionHeader("Address")
                }

                // Bio
                Section {
                    TextEditor(text: $bio)
                        .font(.system(size: 13))
                        .frame(minHeight: 80, maxHeight: 120)
                        .padding(4)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onChange(of: bio) { _, val in prefs.userBio = val }

                    Text("Tell Dockwright about yourself — role, interests, preferences. This helps personalize responses.")
                        .font(DockwrightTheme.Typography.caption)
                        .foregroundStyle(.tertiary)
                } header: {
                    sectionHeader("About you")
                }

                // Assistant name
                Section {
                    TextField("Dockwright", text: $assistantNickname)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: assistantNickname) { _, val in prefs.assistantName = val.isEmpty ? "Dockwright" : val }

                    Text("Give your assistant a custom name. It will introduce itself with this name and respond to it.")
                        .font(DockwrightTheme.Typography.caption)
                        .foregroundStyle(.tertiary)
                } header: {
                    sectionHeader("Assistant name")
                }

                // Preview
                chatPreview
            }
            .padding(.horizontal, DockwrightTheme.Spacing.xl)
            .padding(.vertical, DockwrightTheme.Spacing.lg)
        }
        .onAppear { loadProfileImage() }
    }

    // MARK: - Profile Picture

    private var profilePictureSection: some View {
        VStack(spacing: DockwrightTheme.Spacing.md) {
            Button {
                pickImage()
            } label: {
                ZStack {
                    if let img = profileImage {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 96, height: 96)
                            .clipShape(Circle())
                    } else {
                        Circle()
                            .fill(DockwrightTheme.primary.opacity(0.2))
                            .frame(width: 96, height: 96)
                            .overlay {
                                if name.isEmpty {
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 36))
                                        .foregroundStyle(DockwrightTheme.primary.opacity(0.5))
                                } else {
                                    Text(initials)
                                        .font(.system(size: 32, weight: .semibold))
                                        .foregroundStyle(DockwrightTheme.primary)
                                }
                            }
                    }

                    // Camera badge
                    Circle()
                        .fill(DockwrightTheme.primary)
                        .frame(width: 28, height: 28)
                        .overlay {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.white)
                        }
                        .offset(x: 34, y: 34)
                }
            }
            .buttonStyle(.plain)

            if profileImage != nil {
                Button("Remove photo") {
                    profileImage = nil
                    try? FileManager.default.removeItem(atPath: Self.profileImagePath)
                }
                .font(.system(size: 12))
                .foregroundStyle(.red.opacity(0.8))
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Chat Preview

    private var chatPreview: some View {
        Section {
            VStack(alignment: .leading, spacing: DockwrightTheme.Spacing.sm) {
                // User message preview
                HStack(alignment: .top, spacing: 8) {
                    Spacer()
                    Text("What's on my screen?")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    userAvatarView(size: 24)
                }

                // Assistant message preview
                HStack(alignment: .top, spacing: 8) {
                    dockwrightAvatarView(size: 24)
                    Text("I can see you're in the Settings screen of Dockwright...")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.85))
                    Spacer()
                }
            }
            .padding(DockwrightTheme.Spacing.md)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } header: {
            sectionHeader("Preview")
        }
    }

    // MARK: - Avatar Views (reused by MessageBubble)

    func userAvatarView(size: CGFloat) -> some View {
        Group {
            if let img = profileImage {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else if !name.isEmpty {
                Circle()
                    .fill(DockwrightTheme.primary.opacity(0.2))
                    .frame(width: size, height: size)
                    .overlay {
                        Text(initials)
                            .font(.system(size: size * 0.4, weight: .semibold))
                            .foregroundStyle(DockwrightTheme.primary)
                    }
            } else {
                Circle()
                    .fill(DockwrightTheme.primary.opacity(0.15))
                    .frame(width: size, height: size)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.45))
                            .foregroundStyle(DockwrightTheme.primary.opacity(0.5))
                    }
            }
        }
    }

    static func dockwrightAvatarView(size: CGFloat) -> some View {
        Group {
            if let appIcon = NSImage(named: "AppIcon") {
                Image(nsImage: appIcon)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(DockwrightTheme.primary.opacity(0.2))
                    .frame(width: size, height: size)
                    .overlay {
                        Image(systemName: "brain")
                            .font(.system(size: size * 0.45))
                            .foregroundStyle(DockwrightTheme.primary)
                    }
            }
        }
    }

    private func dockwrightAvatarView(size: CGFloat) -> some View {
        Self.dockwrightAvatarView(size: size)
    }

    // MARK: - Helpers

    private var initials: String {
        let parts = name.split(separator: " ")
        let first = parts.first?.prefix(1) ?? ""
        let last = parts.count > 1 ? parts.last!.prefix(1) : ""
        return "\(first)\(last)".uppercased()
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a profile picture"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = NSImage(contentsOf: url) else { return }

        // Resize to 256x256 and save as PNG
        let resized = resizeImage(image, to: NSSize(width: 256, height: 256))
        if let tiff = resized.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: Self.profileImagePath))
        }
        profileImage = resized
    }

    private func loadProfileImage() {
        let path = Self.profileImagePath
        if FileManager.default.fileExists(atPath: path) {
            profileImage = NSImage(contentsOfFile: path)
        }
    }

    private func resizeImage(_ image: NSImage, to size: NSSize) -> NSImage {
        let newImage = NSImage(size: size)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }

    /// Load user profile image from disk (static, for use by MessageBubble).
    static func loadUserAvatar() -> NSImage? {
        let path = profileImagePath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return NSImage(contentsOfFile: path)
    }
}
