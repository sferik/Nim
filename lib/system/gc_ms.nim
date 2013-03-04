#
#
#            Nimrod's Runtime Library
#        (c) Copyright 2013 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# A simple mark&sweep garbage collector for Nimrod. Define the 
# symbol ``gcUseBitvectors`` to generate a variant of this GC.
{.push profiler:off.}

const
  InitialThreshold = 4*1024*1024 # X MB because marking&sweeping is slow
  withBitvectors = defined(gcUseBitvectors) 
  # bitvectors are significantly faster for GC-bench, but slower for
  # bootstrapping and use more memory
  rcWhite = 0
  rcGrey = 1   # unused
  rcBlack = 2

template mulThreshold(x): expr {.immediate.} = x * 2

when defined(memProfiler):
  proc nimProfile(requestedSize: int)

type
  TWalkOp = enum
    waMarkGlobal,  # we need to mark conservatively for global marker procs
                   # as these may refer to a global var and not to a thread
                   # local 
    waMarkPrecise  # fast precise marking

  TFinalizer {.compilerproc.} = proc (self: pointer) {.nimcall.}
    # A ref type can have a finalizer that is called before the object's
    # storage is freed.
  
  TGlobalMarkerProc = proc () {.nimcall.}

  TGcStat = object
    collections: int         # number of performed full collections
    maxThreshold: int        # max threshold that has been set
    maxStackSize: int        # max stack size
    freedObjects: int        # max entries in cycle table  
  
  TGcHeap = object           # this contains the zero count and
                             # non-zero count table
    stackBottom: pointer
    cycleThreshold: int
    when withBitvectors:
      allocated, marked: TCellSet
    tempStack: TCellSeq      # temporary stack for recursion elimination
    recGcLock: int           # prevent recursion via finalizers; no thread lock
    region: TMemRegion       # garbage collected region
    stat: TGcStat

var
  gch {.rtlThreadVar.}: TGcHeap

when not defined(useNimRtl):
  InstantiateForRegion(gch.region)

template acquire(gch: TGcHeap) = 
  when hasThreadSupport and hasSharedHeap:
    AcquireSys(HeapLock)

template release(gch: TGcHeap) = 
  when hasThreadSupport and hasSharedHeap:
    releaseSys(HeapLock)

template gcAssert(cond: bool, msg: string) =
  when defined(useGcAssert):
    if not cond:
      echo "[GCASSERT] ", msg
      quit 1

proc cellToUsr(cell: PCell): pointer {.inline.} =
  # convert object (=pointer to refcount) to pointer to userdata
  result = cast[pointer](cast[TAddress](cell)+%TAddress(sizeof(TCell)))

proc usrToCell(usr: pointer): PCell {.inline.} =
  # convert pointer to userdata to object (=pointer to refcount)
  result = cast[PCell](cast[TAddress](usr)-%TAddress(sizeof(TCell)))

proc canbeCycleRoot(c: PCell): bool {.inline.} =
  result = ntfAcyclic notin c.typ.flags

proc extGetCellType(c: pointer): PNimType {.compilerproc.} =
  # used for code generation concerning debugging
  result = usrToCell(c).typ

proc unsureAsgnRef(dest: ppointer, src: pointer) {.inline.} =
  dest[] = src

proc internRefcount(p: pointer): int {.exportc: "getRefcount".} =
  result = 0

var
  globalMarkersLen: int
  globalMarkers: array[0.. 7_000, TGlobalMarkerProc]

proc nimRegisterGlobalMarker(markerProc: TGlobalMarkerProc) {.compilerProc.} =
  if globalMarkersLen <= high(globalMarkers):
    globalMarkers[globalMarkersLen] = markerProc
    inc globalMarkersLen
  else:
    echo "[GC] cannot register global variable; too many global variables"
    quit 1

# this that has to equals zero, otherwise we have to round up UnitsPerPage:
when BitsPerPage mod (sizeof(int)*8) != 0:
  {.error: "(BitsPerPage mod BitsPerUnit) should be zero!".}

# forward declarations:
proc collectCT(gch: var TGcHeap)
proc IsOnStack*(p: pointer): bool {.noinline.}
proc forAllChildren(cell: PCell, op: TWalkOp)
proc doOperation(p: pointer, op: TWalkOp)
proc forAllChildrenAux(dest: Pointer, mt: PNimType, op: TWalkOp)
# we need the prototype here for debugging purposes

proc prepareDealloc(cell: PCell) =
  if cell.typ.finalizer != nil:
    # the finalizer could invoke something that
    # allocates memory; this could trigger a garbage
    # collection. Since we are already collecting we
    # prevend recursive entering here by a lock.
    # XXX: we should set the cell's children to nil!
    inc(gch.recGcLock)
    (cast[TFinalizer](cell.typ.finalizer))(cellToUsr(cell))
    dec(gch.recGcLock)

proc nimGCref(p: pointer) {.compilerProc, inline.} = 
  # we keep it from being collected by pretending it's not even allocated:
  when withBitvectors: excl(gch.allocated, usrToCell(p))
  else: usrToCell(p).refcount = rcBlack
proc nimGCunref(p: pointer) {.compilerProc, inline.} = 
  when withBitvectors: incl(gch.allocated, usrToCell(p))
  else: usrToCell(p).refcount = rcWhite

proc initGC() =
  when not defined(useNimRtl):
    gch.cycleThreshold = InitialThreshold
    gch.stat.collections = 0
    gch.stat.maxThreshold = 0
    gch.stat.maxStackSize = 0
    init(gch.tempStack)
    when withBitvectors:
      Init(gch.allocated)
      init(gch.marked)

proc forAllSlotsAux(dest: pointer, n: ptr TNimNode, op: TWalkOp) =
  var d = cast[TAddress](dest)
  case n.kind
  of nkSlot: forAllChildrenAux(cast[pointer](d +% n.offset), n.typ, op)
  of nkList:
    for i in 0..n.len-1:
      forAllSlotsAux(dest, n.sons[i], op)
  of nkCase:
    var m = selectBranch(dest, n)
    if m != nil: forAllSlotsAux(dest, m, op)
  of nkNone: sysAssert(false, "forAllSlotsAux")

proc forAllChildrenAux(dest: Pointer, mt: PNimType, op: TWalkOp) =
  var d = cast[TAddress](dest)
  if dest == nil: return # nothing to do
  if ntfNoRefs notin mt.flags:
    case mt.Kind
    of tyRef, tyString, tySequence: # leaf:
      doOperation(cast[ppointer](d)[], op)
    of tyObject, tyTuple:
      forAllSlotsAux(dest, mt.node, op)
    of tyArray, tyArrayConstr, tyOpenArray:
      for i in 0..(mt.size div mt.base.size)-1:
        forAllChildrenAux(cast[pointer](d +% i *% mt.base.size), mt.base, op)
    else: nil

proc forAllChildren(cell: PCell, op: TWalkOp) =
  gcAssert(cell != nil, "forAllChildren: 1")
  gcAssert(cell.typ != nil, "forAllChildren: 2")
  gcAssert cell.typ.kind in {tyRef, tySequence, tyString}, "forAllChildren: 3"
  let marker = cell.typ.marker
  if marker != nil:
    marker(cellToUsr(cell), op.int)
  else:
    case cell.typ.Kind
    of tyRef: # common case
      forAllChildrenAux(cellToUsr(cell), cell.typ.base, op)
    of tySequence:
      var d = cast[TAddress](cellToUsr(cell))
      var s = cast[PGenericSeq](d)
      if s != nil:
        for i in 0..s.len-1:
          forAllChildrenAux(cast[pointer](d +% i *% cell.typ.base.size +%
            GenericSeqSize), cell.typ.base, op)
    else: nil

proc rawNewObj(typ: PNimType, size: int, gch: var TGcHeap): pointer =
  # generates a new object and sets its reference counter to 0
  acquire(gch)
  gcAssert(typ.kind in {tyRef, tyString, tySequence}, "newObj: 1")
  collectCT(gch)
  var res = cast[PCell](rawAlloc(gch.region, size + sizeof(TCell)))
  gcAssert((cast[TAddress](res) and (MemAlign-1)) == 0, "newObj: 2")
  # now it is buffered in the ZCT
  res.typ = typ
  when leakDetector and not hasThreadSupport:
    if framePtr != nil and framePtr.prev != nil:
      res.filename = framePtr.prev.filename
      res.line = framePtr.prev.line
  res.refcount = 0
  release(gch)
  when withBitvectors: incl(gch.allocated, res)
  result = cellToUsr(res)

{.pop.}

proc newObj(typ: PNimType, size: int): pointer {.compilerRtl.} =
  result = rawNewObj(typ, size, gch)
  zeroMem(result, size)
  when defined(memProfiler): nimProfile(size)

proc newSeq(typ: PNimType, len: int): pointer {.compilerRtl.} =
  # `newObj` already uses locks, so no need for them here.
  let size = addInt(mulInt(len, typ.base.size), GenericSeqSize)
  result = newObj(typ, size)
  cast[PGenericSeq](result).len = len
  cast[PGenericSeq](result).reserved = len
  when defined(memProfiler): nimProfile(size)

proc newObjRC1(typ: PNimType, size: int): pointer {.compilerRtl.} =
  result = rawNewObj(typ, size, gch)
  zeroMem(result, size)
  when defined(memProfiler): nimProfile(size)
  
proc newSeqRC1(typ: PNimType, len: int): pointer {.compilerRtl.} =
  let size = addInt(mulInt(len, typ.base.size), GenericSeqSize)
  result = newObj(typ, size)
  cast[PGenericSeq](result).len = len
  cast[PGenericSeq](result).reserved = len
  when defined(memProfiler): nimProfile(size)
  
proc growObj(old: pointer, newsize: int, gch: var TGcHeap): pointer =
  acquire(gch)
  collectCT(gch)
  var ol = usrToCell(old)
  sysAssert(ol.typ != nil, "growObj: 1")
  gcAssert(ol.typ.kind in {tyString, tySequence}, "growObj: 2")
  
  var res = cast[PCell](rawAlloc(gch.region, newsize + sizeof(TCell)))
  var elemSize = 1
  if ol.typ.kind != tyString: elemSize = ol.typ.base.size
  
  var oldsize = cast[PGenericSeq](old).len*elemSize + GenericSeqSize
  copyMem(res, ol, oldsize + sizeof(TCell))
  zeroMem(cast[pointer](cast[TAddress](res)+% oldsize +% sizeof(TCell)),
          newsize-oldsize)
  sysAssert((cast[TAddress](res) and (MemAlign-1)) == 0, "growObj: 3")
  when withBitvectors: excl(gch.allocated, ol)
  when reallyDealloc: rawDealloc(gch.region, ol)
  else:
    zeroMem(ol, sizeof(TCell))
  when withBitvectors: incl(gch.allocated, res)
  release(gch)
  result = cellToUsr(res)
  when defined(memProfiler): nimProfile(newsize-oldsize)

proc growObj(old: pointer, newsize: int): pointer {.rtl.} =
  result = growObj(old, newsize, gch)

{.push profiler:off.}

# ----------------- collector -----------------------------------------------

proc mark(gch: var TGcHeap, c: PCell) =
  when withBitvectors:
    incl(gch.marked, c)
    gcAssert gch.tempStack.len == 0, "stack not empty!"
    forAllChildren(c, waMarkPrecise)
    while gch.tempStack.len > 0:
      dec gch.tempStack.len
      var d = gch.tempStack.d[gch.tempStack.len]
      if not containsOrIncl(gch.marked, d):
        forAllChildren(d, waMarkPrecise)
  else:
    c.refCount = rcBlack
    gcAssert gch.tempStack.len == 0, "stack not empty!"
    forAllChildren(c, waMarkPrecise)
    while gch.tempStack.len > 0:
      dec gch.tempStack.len
      var d = gch.tempStack.d[gch.tempStack.len]
      if d.refcount == rcWhite:
        d.refCount = rcBlack
        forAllChildren(d, waMarkPrecise)

proc doOperation(p: pointer, op: TWalkOp) =
  if p == nil: return
  var c: PCell = usrToCell(p)
  gcAssert(c != nil, "doOperation: 1")
  case op
  of waMarkGlobal:
    when hasThreadSupport:
      # could point to a cell which we don't own and don't want to touch/trace
      if isAllocatedPtr(gch.region, c):
        mark(gch, c)
    else:
      mark(gch, c)
  of waMarkPrecise: add(gch.tempStack, c)

proc nimGCvisit(d: pointer, op: int) {.compilerRtl.} =
  doOperation(d, TWalkOp(op))

proc freeCyclicCell(gch: var TGcHeap, c: PCell) =
  inc gch.stat.freedObjects
  prepareDealloc(c)
  when reallyDealloc: rawDealloc(gch.region, c)
  else:
    gcAssert(c.typ != nil, "freeCyclicCell")
    zeroMem(c, sizeof(TCell))

proc sweep(gch: var TGcHeap) =
  when withBitvectors:
    for c in gch.allocated.elementsExcept(gch.marked):
      gch.allocated.excl(c)
      freeCyclicCell(gch, c)
  else:
    for x in allObjects(gch.region):
      if isCell(x):
        # cast to PCell is correct here:
        var c = cast[PCell](x)
        if c.refcount == rcBlack: c.refcount = rcWhite
        else: freeCyclicCell(gch, c)

proc markGlobals(gch: var TGcHeap) =
  for i in 0 .. < globalMarkersLen: globalMarkers[i]()

proc gcMark(gch: var TGcHeap, p: pointer) {.inline.} =
  # the addresses are not as cells on the stack, so turn them to cells:
  var cell = usrToCell(p)
  var c = cast[TAddress](cell)
  if c >% PageSize:
    # fast check: does it look like a cell?
    var objStart = cast[PCell](interiorAllocatedPtr(gch.region, cell))
    if objStart != nil:
      mark(gch, objStart)
  
# ----------------- stack management --------------------------------------
#  inspired from Smart Eiffel

when defined(sparc):
  const stackIncreases = false
elif defined(hppa) or defined(hp9000) or defined(hp9000s300) or
     defined(hp9000s700) or defined(hp9000s800) or defined(hp9000s820):
  const stackIncreases = true
else:
  const stackIncreases = false

when not defined(useNimRtl):
  {.push stack_trace: off.}
  proc setStackBottom(theStackBottom: pointer) =
    #c_fprintf(c_stdout, "stack bottom: %p;\n", theStackBottom)
    # the first init must be the one that defines the stack bottom:
    if gch.stackBottom == nil: gch.stackBottom = theStackBottom
    else:
      var a = cast[TAddress](theStackBottom) # and not PageMask - PageSize*2
      var b = cast[TAddress](gch.stackBottom)
      #c_fprintf(c_stdout, "old: %p new: %p;\n",gch.stackBottom,theStackBottom)
      when stackIncreases:
        gch.stackBottom = cast[pointer](min(a, b))
      else:
        gch.stackBottom = cast[pointer](max(a, b))
  {.pop.}

proc stackSize(): int {.noinline.} =
  var stackTop {.volatile.}: pointer
  result = abs(cast[int](addr(stackTop)) - cast[int](gch.stackBottom))

when defined(sparc): # For SPARC architecture.
  proc isOnStack(p: pointer): bool =
    var stackTop {.volatile.}: pointer
    stackTop = addr(stackTop)
    var b = cast[TAddress](gch.stackBottom)
    var a = cast[TAddress](stackTop)
    var x = cast[TAddress](p)
    result = a <=% x and x <=% b

  proc markStackAndRegisters(gch: var TGcHeap) {.noinline, cdecl.} =
    when defined(sparcv9):
      asm  """"flushw \n" """
    else:
      asm  """"ta      0x3   ! ST_FLUSH_WINDOWS\n" """

    var
      max = gch.stackBottom
      sp: PPointer
      stackTop: array[0..1, pointer]
    sp = addr(stackTop[0])
    # Addresses decrease as the stack grows.
    while sp <= max:
      gcMark(gch, sp[])
      sp = cast[ppointer](cast[TAddress](sp) +% sizeof(pointer))

elif defined(ELATE):
  {.error: "stack marking code is to be written for this architecture".}

elif stackIncreases:
  # ---------------------------------------------------------------------------
  # Generic code for architectures where addresses increase as the stack grows.
  # ---------------------------------------------------------------------------
  proc isOnStack(p: pointer): bool =
    var stackTop {.volatile.}: pointer
    stackTop = addr(stackTop)
    var a = cast[TAddress](gch.stackBottom)
    var b = cast[TAddress](stackTop)
    var x = cast[TAddress](p)
    result = a <=% x and x <=% b

  var
    jmpbufSize {.importc: "sizeof(jmp_buf)", nodecl.}: int
      # a little hack to get the size of a TJmpBuf in the generated C code
      # in a platform independant way

  proc markStackAndRegisters(gch: var TGcHeap) {.noinline, cdecl.} =
    var registers: C_JmpBuf
    if c_setjmp(registers) == 0'i32: # To fill the C stack with registers.
      var max = cast[TAddress](gch.stackBottom)
      var sp = cast[TAddress](addr(registers)) +% jmpbufSize -% sizeof(pointer)
      # sp will traverse the JMP_BUF as well (jmp_buf size is added,
      # otherwise sp would be below the registers structure).
      while sp >=% max:
        gcMark(gch, cast[ppointer](sp)[])
        sp = sp -% sizeof(pointer)

else:
  # ---------------------------------------------------------------------------
  # Generic code for architectures where addresses decrease as the stack grows.
  # ---------------------------------------------------------------------------
  proc isOnStack(p: pointer): bool =
    var stackTop {.volatile.}: pointer
    stackTop = addr(stackTop)
    var b = cast[TAddress](gch.stackBottom)
    var a = cast[TAddress](stackTop)
    var x = cast[TAddress](p)
    result = a <=% x and x <=% b

  proc markStackAndRegisters(gch: var TGcHeap) {.noinline, cdecl.} =
    # We use a jmp_buf buffer that is in the C stack.
    # Used to traverse the stack and registers assuming
    # that 'setjmp' will save registers in the C stack.
    type PStackSlice = ptr array [0..7, pointer]
    var registers: C_JmpBuf
    if c_setjmp(registers) == 0'i32: # To fill the C stack with registers.
      var max = cast[TAddress](gch.stackBottom)
      var sp = cast[TAddress](addr(registers))
      # loop unrolled:
      while sp <% max - 8*sizeof(pointer):
        gcMark(gch, cast[PStackSlice](sp)[0])
        gcMark(gch, cast[PStackSlice](sp)[1])
        gcMark(gch, cast[PStackSlice](sp)[2])
        gcMark(gch, cast[PStackSlice](sp)[3])
        gcMark(gch, cast[PStackSlice](sp)[4])
        gcMark(gch, cast[PStackSlice](sp)[5])
        gcMark(gch, cast[PStackSlice](sp)[6])
        gcMark(gch, cast[PStackSlice](sp)[7])
        sp = sp +% sizeof(pointer)*8
      # last few entries:
      while sp <=% max:
        gcMark(gch, cast[ppointer](sp)[])
        sp = sp +% sizeof(pointer)

# ----------------------------------------------------------------------------
# end of non-portable code
# ----------------------------------------------------------------------------

proc collectCTBody(gch: var TGcHeap) =
  gch.stat.maxStackSize = max(gch.stat.maxStackSize, stackSize())
  prepareForInteriorPointerChecking(gch.region)
  markStackAndRegisters(gch)
  markGlobals(gch)
  sweep(gch)
  
  inc(gch.stat.collections)
  when withBitvectors:
    deinit(gch.marked)
    init(gch.marked)
  gch.cycleThreshold = max(InitialThreshold, getOccupiedMem().mulThreshold)
  gch.stat.maxThreshold = max(gch.stat.maxThreshold, gch.cycleThreshold)
  sysAssert(allocInv(gch.region), "collectCT: end")
  
proc collectCT(gch: var TGcHeap) =
  if getOccupiedMem(gch.region) >= gch.cycleThreshold and gch.recGcLock == 0:
    collectCTBody(gch)

when not defined(useNimRtl):
  proc GC_disable() = 
    when hasThreadSupport and hasSharedHeap:
      atomicInc(gch.recGcLock, 1)
    else:
      inc(gch.recGcLock)
  proc GC_enable() =
    if gch.recGcLock > 0: 
      when hasThreadSupport and hasSharedHeap:
        atomicDec(gch.recGcLock, 1)
      else:
        dec(gch.recGcLock)

  proc GC_setStrategy(strategy: TGC_Strategy) = nil

  proc GC_enableMarkAndSweep() =
    gch.cycleThreshold = InitialThreshold

  proc GC_disableMarkAndSweep() =
    gch.cycleThreshold = high(gch.cycleThreshold)-1
    # set to the max value to suppress the cycle detector

  proc GC_fullCollect() =
    acquire(gch)
    var oldThreshold = gch.cycleThreshold
    gch.cycleThreshold = 0 # forces cycle collection
    collectCT(gch)
    gch.cycleThreshold = oldThreshold
    release(gch)

  proc GC_getStatistics(): string =
    GC_disable()
    result = "[GC] total memory: " & $getTotalMem() & "\n" &
             "[GC] occupied memory: " & $getOccupiedMem() & "\n" &
             "[GC] collections: " & $gch.stat.collections & "\n" &
             "[GC] max threshold: " & $gch.stat.maxThreshold & "\n" &
             "[GC] freed objects: " & $gch.stat.freedObjects & "\n" &
             "[GC] max stack size: " & $gch.stat.maxStackSize & "\n"
    GC_enable()

{.pop.}