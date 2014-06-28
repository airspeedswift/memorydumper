#!/Applications/Xcode6-Beta.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift -i -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.9.sdk

import Foundation
import Darwin


struct Memory {
    let buffer: UInt8[]
    let isMalloc: Bool
    
    static func readIntoArray(ptr: UInt, var _ buffer: UInt8[]) -> Bool {
        let result = buffer.withUnsafePointerToElements {
            (targetPtr: UnsafePointer<UInt8>) -> kern_return_t in
            
            let ptr64 = UInt64(ptr)
            let target: UInt = reinterpretCast(targetPtr)
            let target64 = UInt64(target)
            var outsize: mach_vm_size_t = 0
            return mach_vm_read_overwrite(mach_task_self_, ptr64, mach_vm_size_t(buffer.count), target64, &outsize)
        }
        return result == KERN_SUCCESS
    }
    
    static func read(ptr: UInt, knownSize: Int? = nil) -> Memory? {
        let convertedPtr: UnsafePointer<Int> = reinterpretCast(ptr)
        var length = Int(malloc_size(convertedPtr))
        let isMalloc = length > 0
        if length == 0 {
            length = 64
        }
        
        if knownSize {
            length = knownSize!
        }
        
        var result = UInt8[](count: length, repeatedValue: 0)
        let success = readIntoArray(ptr, result)
        return (success
            ? Memory(buffer: result, isMalloc: isMalloc)
            : nil)
    }
    
    func scanPointers() -> PointerAndOffset[] {
        var pointers = PointerAndOffset[]()
        buffer.withUnsafePointerToElements {
            (memPtr: UnsafePointer<UInt8>) -> Void in
            
            let ptrptr: UnsafePointer<UInt> = reinterpretCast(memPtr)
            let count = self.buffer.count / 8
            for i in 0..count {
                pointers.append(PointerAndOffset(pointer: ptrptr[i], offset: i * 8))
            }
        }
        return pointers
    }
    
    func scanStrings() -> String[] {
        let lowerBound: UInt8 = 32
        let upperBound: UInt8 = 126
        
        var current = UInt8[]()
        var strings = String[]()
        func reset() {
            if current.count >= 4 {
                let str = NSMutableString(capacity: current.count)
                for byte in current {
                    str.appendFormat("%c", byte)
                }
                strings.append(str)
            }
            current.removeAll()
        }
        for byte in buffer {
            if byte >= lowerBound && byte <= upperBound {
                current.append(byte)
            } else {
                reset()
            }
        }
        reset()
        
        return strings
    }
    
    func hex() -> String {
        return hexFromArray(buffer)
    }
}

func formatPointer(ptr: UInt) -> String {
    return NSString(format: "0x%0*llx", sizeof(UInt.self) * 2, ptr)
}


func hexFromArray(mem: UInt8[]) -> String {
    let spacesInterval = 8
    let str = NSMutableString(capacity: mem.count * 2)
    for (index, byte) in enumerate(mem) {
        if index > 0 && (index % spacesInterval) == 0 {
            str.appendString(" ")
        }
        str.appendFormat("%02x", byte)
    }
    return str
}

struct PointerAndOffset {
    let pointer: UInt
    let offset: Int
}

enum Alignment {
    case Right
    case Left
}

func pad(value: Any, minWidth: Int, padChar: String = " ", align: Alignment = .Right) -> String {
    var str = "\(value)"
    var accumulator = ""
    
    if align == .Left {
        accumulator += str
    }
    
    if minWidth > countElements(str) {
        for i in 0..(minWidth - countElements(str)) {
            accumulator += padChar
        }
    }
    
    if align == .Right {
        accumulator += str
    }
    
    return accumulator
}

func limit(str: String, maxLength: Int, continuation: String = "...") -> String {
    if countElements(str) <= maxLength {
        return str
    }
    
    let start = str.startIndex
    let truncationPoint = advance(start, maxLength)
    return str[start..truncationPoint] + continuation
}

enum Term: String {
    case Default = "39"
    case Red = "31"
    case Green = "32"
    case Yellow = "33"
    case Blue = "34"
    case Magenta = "35"
    case Cyan = "36"
    
    func escapeSequence() -> String {
        return "\x1B[\(self.toRaw())m"
    }
    
    func wrap(contents: String) -> String {
        return "\(escapeSequence())\(contents)\(Default.escapeSequence())"
    }
}

class ScanEntry {
    let parent: ScanEntry?
    var parentOffset: Int
    let address: UInt
    var index: Int
    
    init(parent: ScanEntry?, parentOffset: Int, address: UInt, index: Int) {
        self.parent = parent
        self.parentOffset = parentOffset
        self.address = address
        self.index = index
    }
}

struct ObjCClass {
    let address: UInt
    let name: String
}

func AllClasses() -> ObjCClass[] {
    var count: CUnsignedInt = 0
    let classList = objc_copyClassList(&count)
    
    var result = ObjCClass[]()
    
    for i in 0..count {
        let rawClass: AnyClass! = classList[Int(i)]
        let address: UInt = reinterpretCast(rawClass)
        let name = NSStringFromClass(rawClass)
        result.append(ObjCClass(address: address, name: name))
    }
    
    return result
}

var classMap = Dictionary<UInt, ObjCClass>()
for c in AllClasses() { classMap[c.address] = c }
//for (addr, objCClass) in classMap {
//    println("\(formatPointer(addr)) \(objCClass.name)")
//}

class ScanResult {
    let entry: ScanEntry
    let parent: ScanResult?
    let memory: Memory
    var children = ScanResult[]()
    var indent = 0
    var color: Term = .Default
    
    init(entry: ScanEntry, parent: ScanResult?, memory: Memory) {
        self.entry = entry
        self.parent = parent
        self.memory = memory
    }
    
    var name: String {
        return formatPointer(entry.address)
    }
    
    func dump() {
        if let parent = entry.parent {
            print("(")
            print(self.parent!.color.wrap("\(pad(parent.index, 3)), \(self.parent!.name)@\(pad(entry.parentOffset, 3, align: .Left))"))
            print(") <- ")
        } else {
            print("                                 ")
        }
        
        print(color.wrap("\(pad(entry.index, 3)) \(formatPointer(entry.address))"))
        print(": ")
        
        print("\(pad(memory.buffer.count, 5)) bytes ")
        print(memory.isMalloc ? "<malloc> " : "<unknwn> ")
        
        print(limit(memory.hex(), 67))
        
        if let objCClass = classMap[entry.address] {
            print(" ObjC class \(objCClass.name)")
        }
        
        let strings = memory.scanStrings()
        if strings.count > 0 {
            print(" -- strings: (")
            print(", ".join(strings))
            print(")")
        }
        println()
    }
    
    func recursiveDump() {
        var entryColorIndex = 0
        let entryColors: Term[] = [ .Red, .Green, .Yellow, .Blue, .Magenta, .Cyan ]
        func nextColor() -> Term {
            return entryColors[entryColorIndex++ % entryColors.count]
        }
        
        var chain = [self]
        while chain.count > 0 {
            let result = chain.removeLast()
            
            if result.children.count > 0 {
                result.color = nextColor()
            }
            
            for i in 0..result.indent {
                print("  ")
            }
            result.dump()
            for child in result.children {
                child.indent = result.indent + 1
                chain.append(child)
            }
        }
    }
}

func dumpmem<T>(var x: T) -> ScanResult {
    var count = 0
    var seen = Dictionary<UInt, Bool>()
    var toScan = Array<ScanEntry>()
    
    var results = Dictionary<UInt, ScanResult>()
    
    return withUnsafePointer(&x) {
        (ptr: UnsafePointer<T>) -> ScanResult in
        
        let firstAddr: UInt = reinterpretCast(ptr)
        let firstEntry = ScanEntry(parent: nil, parentOffset: 0, address: firstAddr, index: 0)
        seen[firstAddr] = true
        toScan.append(firstEntry)
        
        while toScan.count > 0 && count < 150 {
            let entry = toScan.removeLast()
            entry.index = count
            
            let memory: Memory! = Memory.read(entry.address, knownSize: count == 0 ? sizeof(T.self) : nil)
            
            if memory {
                count++
                let parent = entry.parent.map{ results[$0.address] }?
                let result = ScanResult(entry: entry, parent: parent, memory: memory)
                parent?.children.append(result)
                results[entry.address] = result
                
                let pointersAndOffsets = memory.scanPointers()
                for pointerAndOffset in pointersAndOffsets {
                    let pointer = pointerAndOffset.pointer
                    let offset = pointerAndOffset.offset
                    if !seen[pointer] {
                        seen[pointer] = true
                        let newEntry = ScanEntry(parent: entry, parentOffset: offset, address: pointer, index: count)
                        toScan.insert(newEntry, atIndex: 0)
                    }
                }
            }
        }
        return results[firstAddr]!
    }
}


//dumpmem(42)
//let obj = NSObject()
//println(obj.description)
class TestClass {}
let obj = TestClass()
let result = dumpmem(obj)
result.recursiveDump()

