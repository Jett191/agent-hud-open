/// Arrangements that change one setting at a time: each base, then each base with one setting at each of its other
/// values. A rule checked over them meets every value of every setting, from the default and from the corner the other
/// bases stand at, without laying out the product of all the settings.
struct OneAtATime<Arrangement> {
    private let bases: [Arrangement]
    private(set) var arrangements: [Arrangement]

    init(from bases: Arrangement...) {
        self.bases = bases
        arrangements = bases
    }

    /// These arrangements and each base with `setting` at each of `values` it does not already have.
    func varying<Value: Equatable>(_ setting: WritableKeyPath<Arrangement, Value>, over values: some Collection<Value>) -> Self {
        var next = self
        for base in bases {
            for value in values where value != base[keyPath: setting] {
                var changed = base
                changed[keyPath: setting] = value
                next.arrangements.append(changed)
            }
        }
        return next
    }
}
