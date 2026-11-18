import Contacts
import ContactsUI
import SwiftUI
import GarminModels

/// The people the watch can show as emergency contacts for incident detection. Contacts come from the system picker,
/// which needs no access to the whole address book.
struct EmergencyContactsView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var picking = false

    var body: some View {
        List {
            Section {
                ForEach(app.watch.emergencyContacts) { contact in
                    LabeledContent(contact.name, value: contact.phoneNumber)
                }
                .onDelete { offsets in
                    var contacts = app.watch.emergencyContacts
                    contacts.remove(atOffsets: offsets)
                    app.watch.setEmergencyContacts(contacts)
                }
                Button("Add contact", systemImage: "person.crop.circle.badge.plus") { picking = true }
            } footer: {
                Text("The watch reads this list for incident detection. Swipe a contact to remove it.")
            }
        }
        .navigationTitle("Emergency contacts")
        .background(ContactPicker(isPresented: $picking) { contact in
            app.watch.setEmergencyContacts(app.watch.emergencyContacts + [contact])
        })
    }
}

/// Presents the system contact picker from a host view controller while `isPresented` is true.
struct ContactPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPick: (EmergencyContact) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        guard isPresented, host.presentedViewController == nil else { return }
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        DispatchQueue.main.async { host.present(picker, animated: true) }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency CNContactPickerDelegate {
        private let parent: ContactPicker

        init(_ parent: ContactPicker) {
            self.parent = parent
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            parent.isPresented = false
            guard let number = contact.phoneNumbers.first?.value.stringValue else { return }
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? number
            parent.onPick(EmergencyContact(name: name, phoneNumber: number))
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            parent.isPresented = false
        }
    }
}
