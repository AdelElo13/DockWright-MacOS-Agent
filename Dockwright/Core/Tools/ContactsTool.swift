import Contacts
import Foundation

/// LLM tool for interacting with Contacts via the Contacts framework.
/// Actions: search, get, list_recent, add, birthdays.
nonisolated struct ContactsTool: Tool, @unchecked Sendable {
    let name = "contacts"
    let description = "Manage Contacts: search contacts, get details, list recently contacted, add new contacts, or find upcoming birthdays."

    nonisolated(unsafe) let parametersSchema: [String: Any] = [
        "action": [
            "type": "string",
            "description": "One of: search, get, list_recent, add, birthdays",
        ] as [String: Any],
        "query": [
            "type": "string",
            "description": "Search query — name, email, or phone (for search)",
            "optional": true,
        ] as [String: Any],
        "name": [
            "type": "string",
            "description": "Contact name (for get, add)",
            "optional": true,
        ] as [String: Any],
        "email": [
            "type": "string",
            "description": "Email address (for add)",
            "optional": true,
        ] as [String: Any],
        "phone": [
            "type": "string",
            "description": "Phone number (for add)",
            "optional": true,
        ] as [String: Any],
        "days": [
            "type": "integer",
            "description": "Number of days ahead for upcoming birthdays (default 30)",
            "optional": true,
        ] as [String: Any],
    ]

    private let store = CNContactStore()

    nonisolated init() {}

    func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let action = arguments["action"] as? String else {
            return ToolResult(
                "Missing 'action' parameter. Use: search, get, list_recent, add, birthdays",
                isError: true
            )
        }

        do {
            try await ensureAccess()
        } catch {
            return ToolResult(
                "Contacts access denied. Please grant permission in System Settings > Privacy & Security > Contacts.",
                isError: true
            )
        }

        switch action {
        case "search":
            return searchContacts(arguments)
        case "get":
            return getContact(arguments)
        case "list_recent":
            return listRecentContacts()
        case "add":
            return addContact(arguments)
        case "birthdays":
            return upcomingBirthdays(arguments)
        default:
            return ToolResult(
                "Unknown action: \(action). Use: search, get, list_recent, add, birthdays",
                isError: true
            )
        }
    }

    // MARK: - Access

    private func ensureAccess() async throws {
        let granted = try await store.requestAccess(for: .contacts)
        guard granted else {
            throw ContactsToolError.accessDenied
        }
    }

    // MARK: - Formatting

    private let keysToFetch: [CNKeyDescriptor] = [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactJobTitleKey as CNKeyDescriptor,
        CNContactBirthdayKey as CNKeyDescriptor,
        CNContactPostalAddressesKey as CNKeyDescriptor,
        CNContactNoteKey as CNKeyDescriptor,
        CNContactIdentifierKey as CNKeyDescriptor,
    ]

    private func formatContact(_ contact: CNContact, index: Int, detailed: Bool = false) -> String {
        let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
        var line = "\(index). \(fullName.isEmpty ? "(No Name)" : fullName)"

        if !contact.organizationName.isEmpty {
            line += " — \(contact.organizationName)"
        }

        if !contact.phoneNumbers.isEmpty {
            let phones = contact.phoneNumbers.map { $0.value.stringValue }
            line += "\n   Phone: \(phones.joined(separator: ", "))"
        }

        if !contact.emailAddresses.isEmpty {
            let emails = contact.emailAddresses.map { $0.value as String }
            line += "\n   Email: \(emails.joined(separator: ", "))"
        }

        if detailed {
            if !contact.jobTitle.isEmpty {
                line += "\n   Title: \(contact.jobTitle)"
            }
            if let birthday = contact.birthday {
                let cal = Calendar.current
                if let date = cal.date(from: birthday) {
                    let fmt = DateFormatter()
                    fmt.dateStyle = .medium
                    fmt.timeStyle = .none
                    line += "\n   Birthday: \(fmt.string(from: date))"
                }
            }
            if !contact.postalAddresses.isEmpty {
                let addr = contact.postalAddresses[0].value
                let formatted = CNPostalAddressFormatter.string(from: addr, style: .mailingAddress)
                    .replacingOccurrences(of: "\n", with: ", ")
                line += "\n   Address: \(formatted)"
            }
            if !contact.note.isEmpty {
                let preview = contact.note.count > 100 ? String(contact.note.prefix(100)) + "..." : contact.note
                line += "\n   Notes: \(preview)"
            }
        }

        return line
    }

    // MARK: - Actions

    private func searchContacts(_ args: [String: Any]) -> ToolResult {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return ToolResult("Missing 'query' for search", isError: true)
        }

        let predicate = CNContact.predicateForContacts(matchingName: query)
        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)

            if contacts.isEmpty {
                return ToolResult("No contacts found matching '\(query)'.")
            }

            let capped = Array(contacts.prefix(30))
            var output = "Found \(contacts.count) contact(s) matching '\(query)':\n\n"
            for (idx, contact) in capped.enumerated() {
                output += formatContact(contact, index: idx + 1) + "\n"
            }
            if contacts.count > 30 {
                output += "\n... and \(contacts.count - 30) more results."
            }
            return ToolResult(output)
        } catch {
            return ToolResult("Failed to search contacts: \(error.localizedDescription)", isError: true)
        }
    }

    private func getContact(_ args: [String: Any]) -> ToolResult {
        guard let name = args["name"] as? String, !name.isEmpty else {
            return ToolResult("Missing 'name' for get", isError: true)
        }

        let predicate = CNContact.predicateForContacts(matchingName: name)
        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)

            if contacts.isEmpty {
                return ToolResult("No contact found with name '\(name)'.")
            }

            let contact = contacts[0]
            let output = formatContact(contact, index: 1, detailed: true)
            return ToolResult(output)
        } catch {
            return ToolResult("Failed to get contact: \(error.localizedDescription)", isError: true)
        }
    }

    private func listRecentContacts() -> ToolResult {
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        request.sortOrder = .userDefault

        var contacts: [CNContact] = []
        do {
            try store.enumerateContacts(with: request) { contact, stop in
                contacts.append(contact)
                if contacts.count >= 20 {
                    stop.pointee = true
                }
            }
        } catch {
            return ToolResult("Failed to list contacts: \(error.localizedDescription)", isError: true)
        }

        if contacts.isEmpty {
            return ToolResult("No contacts found.")
        }

        var output = "Contacts (\(contacts.count)):\n\n"
        for (idx, contact) in contacts.enumerated() {
            output += formatContact(contact, index: idx + 1) + "\n"
        }
        return ToolResult(output)
    }

    private func addContact(_ args: [String: Any]) -> ToolResult {
        guard let name = args["name"] as? String, !name.isEmpty else {
            return ToolResult("Missing 'name' for add", isError: true)
        }

        let newContact = CNMutableContact()
        let parts = name.split(separator: " ", maxSplits: 1)
        newContact.givenName = String(parts[0])
        if parts.count > 1 {
            newContact.familyName = String(parts[1])
        }

        if let email = args["email"] as? String, !email.isEmpty {
            newContact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: email as NSString)]
        }

        if let phone = args["phone"] as? String, !phone.isEmpty {
            newContact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))]
        }

        let saveRequest = CNSaveRequest()
        saveRequest.add(newContact, toContainerWithIdentifier: nil)

        do {
            try store.execute(saveRequest)
            var output = "Created contact: \(name)\n"
            if let email = args["email"] as? String, !email.isEmpty {
                output += "Email: \(email)\n"
            }
            if let phone = args["phone"] as? String, !phone.isEmpty {
                output += "Phone: \(phone)\n"
            }
            return ToolResult(output)
        } catch {
            return ToolResult("Failed to add contact: \(error.localizedDescription)", isError: true)
        }
    }

    private func upcomingBirthdays(_ args: [String: Any]) -> ToolResult {
        let days = (args["days"] as? Int) ?? 30
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let endDate = cal.date(byAdding: .day, value: max(1, min(days, 365)), to: today) else {
            return ToolResult("Invalid days value", isError: true)
        }

        let request = CNContactFetchRequest(keysToFetch: keysToFetch)

        var results: [(CNContact, Date)] = []
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                guard let birthday = contact.birthday,
                      let bdayDate = cal.date(from: birthday) else { return }

                // Adjust birthday to this year
                var components = cal.dateComponents([.month, .day], from: bdayDate)
                components.year = cal.component(.year, from: today)
                guard let thisYearBday = cal.date(from: components) else { return }

                if thisYearBday >= today && thisYearBday <= endDate {
                    results.append((contact, thisYearBday))
                }
            }
        } catch {
            return ToolResult("Failed to fetch birthdays: \(error.localizedDescription)", isError: true)
        }

        results.sort { $0.1 < $1.1 }

        if results.isEmpty {
            return ToolResult("No upcoming birthdays in the next \(days) days.")
        }

        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none

        var output = "Upcoming birthdays (next \(days) days) — \(results.count):\n\n"
        for (idx, (contact, date)) in results.enumerated() {
            let fullName = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
            output += "\(idx + 1). \(fullName.isEmpty ? "(No Name)" : fullName) — \(fmt.string(from: date))\n"
        }

        return ToolResult(output)
    }
}

// MARK: - Errors

private enum ContactsToolError: Error, LocalizedError {
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Access to Contacts denied"
        }
    }
}
