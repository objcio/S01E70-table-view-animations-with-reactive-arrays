import Result
import ReactiveSwift
import UIKit

extension Array {
    func binarySearch(for element: Element, isAscending: (Element,Element) -> Bool) -> Int {
        var start = startIndex
        var end = endIndex
        while start < end {
            let middle = start + (end - start) / 2
            if isAscending(self[middle], element) {
                start = middle + 1
            } else {
                end = middle
            }
        }
        assert(start == end)
        return start
    }
}

enum RList<A> {
    case empty
    indirect case cons(A, MutableProperty<RList<A>>)
}

extension RList {
    init(array: [A]) {
        self = .empty
        for element in array.reversed() {
            self = .cons(element, MutableProperty(self))
        }
    }
    
    func reduce<B>(_ initial: B, _ combine: @escaping (B, A) -> B) -> Property<B> {
        let result = MutableProperty(initial)
        func reduceH(list: RList<A>, intermediate: B) {
            switch list {
            case .empty:
                result.value = intermediate
            case let .cons(value, tail):
                let newIntermediate = combine(intermediate, value)
                tail.signal.observeValues { newTail in
                    reduceH(list: newTail, intermediate: newIntermediate)
                }
                reduceH(list: tail.value, intermediate: newIntermediate)
            }
        }
        reduceH(list: self, intermediate: initial)
        return Property(result)
    }
    
}

func append<A>(_ value: A, to list: MutableProperty<RList<A>>) {
    switch list.value {
    case .empty:
        list.value = .cons(value, MutableProperty(.empty))
    case .cons(_, let tail):
        append(value, to: tail)
    }
}

enum ArrayChange<A> {
    case insert(A, at: Int)
    case remove(at: Int)
}

extension Array {
    mutating func apply(_ change: ArrayChange<Element>) {
        switch change {
        case let .insert(value, idx):
            insert(value, at: idx)
        case let .remove(idx):
            remove(at: idx)
        }
    }
    
    func applying(_ change: ArrayChange<Element>) -> [Element] {
        var copy = self
        copy.apply(change)
        return copy
    }
    
    func filteredIndex(for index: Int, _ isIncluded: (Element) -> Bool) -> Int {
        var skipped = 0
        for i in 0..<index {
            if !isIncluded(self[i]) {
                skipped += 1
            }
        }
        return index - skipped
    }
}

struct RArray<A> {
    let initial: [A]
    let changes: Property<RList<ArrayChange<A>>>
    
    var latest: Property<[A]> {
        return changes.flatMap(.latest) { changeList in
            changeList.reduce(self.initial) { $0.applying($1) }
        }
    }
    
    static func mutable(_ initial: [A]) -> (RArray<A>, appendChange: (ArrayChange<A>) -> ()) {
        let changes = MutableProperty<RList<ArrayChange<A>>>(RList(array: []))
        let result = RArray(initial: initial, changes: Property(changes))
        return (result, { change in append(change, to: changes)})

    }
    
    func filter(_ isIncluded: @escaping (A) -> Bool) -> RArray<A> {
        let filtered = initial.filter(isIncluded)
        let (result, addChange) = RArray.mutable(filtered)
        func filterH(_ latestChanges: RList<ArrayChange<A>>) {
            latestChanges.reduce(self.initial) { intermediate, change in
                switch change {
                case let .insert(value, idx) where isIncluded(value):
                    let newIndex = intermediate.filteredIndex(for: idx, isIncluded)
                    addChange(.insert(value, at: newIndex))
                case let .remove(idx) where isIncluded(intermediate[idx]):
                    let newIndex = intermediate.filteredIndex(for: idx, isIncluded)
                    addChange(.remove(at: newIndex))
                default: break
                }
                return intermediate.applying(change)
            }

        }
        changes.signal.observeValues(filterH)
        filterH(changes.value)
        return result
    }
    
    func sort(_ isAscending: @escaping (A,A) -> Bool) -> RArray<A> {
        let sorted = initial.sorted(by: isAscending)
        let (result, addChange) = RArray.mutable(sorted)
        func sortH(_ latestChanges: RList<ArrayChange<A>>) {
            latestChanges.reduce((initial,sorted)) { (x, change: ArrayChange<A>) in
                let intermediate = x.0
                let sorted = x.1
                let newChange: ArrayChange<A>
                switch change {
                case let .insert(value, _):
                    let newIndex = sorted.binarySearch(for: value, isAscending: isAscending)
                    newChange = .insert(value, at: newIndex)
                    addChange(newChange)
                case let .remove(idx):
                    let value = intermediate[idx]
                    let newIndex = sorted.binarySearch(for: value, isAscending: isAscending)
                    newChange = .remove(at: newIndex)
                    addChange(newChange)
                default: break
                }
                return (intermediate.applying(change), sorted.applying(newChange))
            }
            
        }
        changes.signal.observeValues(sortH)
        sortH(changes.value)
        return result
    }
}

final class TableViewController<A>: UITableViewController {
    let configure: (A, UITableViewCell) -> ()
    private(set) var items: [A]
    var disposables: [Any] = []
    
    init(_ items: RArray<A>, configure: @escaping (A, UITableViewCell) -> ()) {
        self.items = items.initial
        self.configure = configure
        super.init(style: .plain)
        disposables.append(items.changes.signal.observeValues { list in
            _ = list.reduce((), { _, change in
                self.apply(change)
            })
        })
    }
    
    func apply(_ change: ArrayChange<A>) {
        items.apply(change)
        switch change {
        case let .insert(_, at: idx):
            tableView.insertRows(at: [IndexPath(row: idx, section: 0)], with: .automatic)
        case let .remove(at: idx):
            tableView.deleteRows(at: [IndexPath(row: idx, section: 0)], with: .automatic)
        }
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError()
    }
    
    override func viewDidLoad() {
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Identifier")
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return items.count
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Identifier", for: indexPath)
        let item = items[indexPath.row]
        configure(item, cell)
        return cell
    }
}

let (arr, change) = RArray.mutable(["one","two","three","four"])

let vc = TableViewController(arr.filter { $0.count > 3 }.sort(>) , configure: { item, cell in
    cell.textLabel?.text = "\(item)"
})

import PlaygroundSupport
PlaygroundPage.current.liveView = vc

DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) {
    change(.insert("five", at: 4))
}
