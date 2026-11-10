import SwiftUI
import HealthKit

private struct EditableProfile {
    var sex: String
    var age: Double
    private var originalHeightCm: Double
    var heightFeet: Double
    var heightInches: Double
    var weightKg: Double
    var ringSize: Double

    private static func splitHeight(_ centimeters: Double) -> (feet: Double, inches: Double) {
        let totalInches = (ImperialUnits.inches(centimeters) * 10).rounded() / 10
        return (floor(totalInches / 12), totalInches.truncatingRemainder(dividingBy: 12))
    }

    var heightCm: Double {
        let original = Self.splitHeight(originalHeightCm)
        if heightFeet == original.feet && heightInches == original.inches {
            return originalHeightCm
        }
        return ImperialUnits.centimeters(heightFeet * 12 + heightInches)
    }

    mutating func importHeight(_ centimeters: Double) {
        originalHeightCm = centimeters
        (heightFeet, heightInches) = Self.splitHeight(centimeters)
    }

    var weightPounds: Double {
        get { ImperialUnits.pounds(weightKg) }
        set { weightKg = ImperialUnits.kilograms(newValue) }
    }

    init(_ profile: Profile?) {
        sex = profile?.sex ?? "M"
        age = profile?.age ?? 30
        let centimeters = (profile?.height_m ?? 1.78) * 100
        originalHeightCm = centimeters
        let height = Self.splitHeight(centimeters)
        heightFeet = height.feet
        heightInches = height.inches
        weightKg = profile?.weight_kg ?? 75
        ringSize = profile?.ring_size ?? 10
    }
}

private enum ProfileStore {
    static var url: URL { DB.url.deletingLastPathComponent().appendingPathComponent("profile.json") }

    static func save(_ p: EditableProfile) throws {
        let object: [String: Any] = [
            "sex": p.sex, "age": p.age, "height_m": p.heightCm / 100,
            "weight_kg": p.weightKg, "ring_size": p.ringSize,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

private struct HealthProfile {
    var sex: String?
    var age: Double?
    var heightCm: Double?
    var weightKg: Double?
}

private enum HealthProfileImporter {
    static func load(completion: @escaping (Result<HealthProfile, Error>) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(.failure(NSError(domain: "open_oura", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "Apple Health is unavailable on this device."])))
            return
        }
        let store = HKHealthStore()
        let dob = HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!
        let biologicalSex = HKObjectType.characteristicType(forIdentifier: .biologicalSex)!
        let height = HKObjectType.quantityType(forIdentifier: .height)!
        let mass = HKObjectType.quantityType(forIdentifier: .bodyMass)!
        let read: Set<HKObjectType> = [dob, biologicalSex, height, mass]
        store.requestAuthorization(toShare: [], read: read) { granted, error in
            if let error { DispatchQueue.main.async { completion(.failure(error)) }; return }
            guard granted else {
                let e = NSError(domain: "open_oura", code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "Apple Health access was not granted."])
                DispatchQueue.main.async { completion(.failure(e)) }
                return
            }

            var result = HealthProfile()
            if let birth = try? store.dateOfBirthComponents().date {
                result.age = Double(Calendar.current.dateComponents([.year], from: birth, to: Date()).year ?? 0)
            }
            if let value = try? store.biologicalSex().biologicalSex {
                switch value {
                case .female: result.sex = "F"
                case .male: result.sex = "M"
                case .other: result.sex = "O"
                default: break
                }
            }

            let group = DispatchGroup()
            func latest(_ type: HKQuantityType, unit: HKUnit, assign: @escaping (Double) -> Void) {
                group.enter()
                let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
                let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1,
                                          sortDescriptors: [sort]) { _, samples, _ in
                    if let sample = samples?.first as? HKQuantitySample {
                        assign(sample.quantity.doubleValue(for: unit))
                    }
                    group.leave()
                }
                store.execute(query)
            }
            latest(height, unit: .meterUnit(with: .centi)) { result.heightCm = $0 }
            latest(mass, unit: .gramUnit(with: .kilo)) { result.weightKg = $0 }
            group.notify(queue: .main) { completion(.success(result)) }
        }
    }
}

struct ProfileSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: EditableProfile
    @State private var importing = false
    @State private var message: String?
    @ObservedObject private var health = HealthExport.shared
    let onSaved: () -> Void

    init(profile: Profile?, onSaved: @escaping () -> Void) {
        _profile = State(initialValue: EditableProfile(profile))
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Biological sex", selection: $profile.sex) {
                        Text("Female").tag("F")
                        Text("Male").tag("M")
                        Text("Other").tag("O")
                    }
                    TextField("Age", value: $profile.age, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                    LabeledContent("Height (ft)") {
                        TextField("Height in feet", value: $profile.heightFeet, format: .number.precision(.fractionLength(0)))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Height (in)") {
                        TextField("Height in inches", value: $profile.heightInches, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Weight (lb)") {
                        TextField("Weight in pounds", value: $profile.weightPounds, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("Ring size", value: $profile.ringSize, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                } header: {
                    Text("Your data")
                } footer: {
                    Text("Stored only on this iPhone and used by the cardiovascular and activity calculations.")
                }

                Section {
                    Button {
                        importing = true; message = nil
                        HealthProfileImporter.load { result in
                            importing = false
                            switch result {
                            case .success(let health):
                                if let v = health.sex { profile.sex = v }
                                if let v = health.age, v > 0 { profile.age = v }
                                if let v = health.heightCm { profile.importHeight(v) }
                                if let v = health.weightKg { profile.weightKg = v }
                                message = "Imported available values from Apple Health."
                            case .failure(let error): message = error.localizedDescription
                            }
                        }
                    } label: {
                        HStack {
                            Label("Import from Apple Health", systemImage: "heart.text.square")
                            Spacer()
                            if importing { ProgressView() }
                        }
                    }
                    .disabled(importing)
                    if let message { Text(message).font(.footnote).foregroundStyle(Obs.ink2) }
                }

                Section {
                    Toggle("Write ring data to Apple Health", isOn: Binding(
                        get: { health.enabled },
                        set: { health.setEnabled($0, summary: SummaryCache.load()) }
                    ))
                    if !health.status.isEmpty {
                        Text(health.status).font(.footnote).foregroundStyle(Obs.ink2)
                    }
                    if health.enabled {
                        Button("Remove Open Oura samples from Health") {
                            health.removeExportedSamples()
                        }
                        .foregroundStyle(Obs.bad)
                    }
                } header: {
                    Text("Apple Health")
                } footer: {
                    Text("Exports workouts (and removes ones the ring no longer detects), sleep stages, heart rate, HRV, resting HR, steps, active calories, and distance. Data stays on this iPhone.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Obs.canvas.ignoresSafeArea())
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try ProfileStore.save(profile)
                            onSaved()
                            dismiss()
                        } catch { message = "Could not save: \(error.localizedDescription)" }
                    }
                }
            }
        }
    }
}
