; *** IR Dump After PGOInstrumentationUse on [module] ***

define internal { i1, i64 } @"pkg::t::tries"(i64 %0, ptr %1, ptr %2, ptr %3) #0 !dbg !403 !prof !499 {
  %5 = call { i1, i64 } @"pkg::t::f"(i64 %0, ptr %3), !dbg !410
  %6 = extractvalue { i1, i64 } %5, 0, !dbg !410
  %7 = extractvalue { i1, i64 } %5, 1, !dbg !410
  %8 = select i1 %6, i64 0, i64 %7, !dbg !410, !prof !480
  br i1 %6, label %9, label %14, !dbg !410, !prof !480

9:                                                ; preds = %4
  %10 = getelementptr { ptr, i64, i64 }, ptr %3, i32 0, i32 2, !dbg !410
  %11 = load i64, ptr %10, align 8, !dbg !410
  %12 = and i64 %11, 4611686018427387904, !dbg !410
  %13 = icmp ne i64 %12, 0, !dbg !410
  br i1 %13, label %90, label %90, !dbg !410, !prof !481

14:                                               ; preds = %4
  %15 = call i1 @"pkg::t::touch"(i64 %0, ptr %3), !dbg !411
  br i1 %15, label %90, label %16, !dbg !411, !prof !482

16:                                               ; preds = %14
  %17 = call { i1, ptr } @"std::collections::dict::Dict::__getitem__[String, Int]"(ptr %1, ptr %2, ptr %3), !dbg !412
  %18 = extractvalue { i1, ptr } %17, 0, !dbg !412
  br i1 %18, label %90, label %19, !dbg !412, !prof !483

19:                                               ; preds = %16
  %20 = icmp eq i64 %0, 7, !dbg !414
  br i1 %20, label %21, label %22, !dbg !415, !prof !484

21:                                               ; preds = %19
  br label %23, !dbg !416

22:                                               ; preds = %19
  br label %23, !dbg !416

23:                                               ; preds = %21, %22
  %24 = phi i1 [ %20, %22 ], [ %20, %21 ], !dbg !413
  br i1 %24, label %90, label %25, !dbg !413, !prof !484

25:                                               ; preds = %23
  %26 = call { i1, i64 } @"std::collections::string::string::String::__int__(::String)"(ptr %2, ptr %3), !dbg !417
  %27 = extractvalue { i1, i64 } %26, 0, !dbg !417
  br label %28, !dbg !417

28:                                               ; preds = %25
  %29 = phi i1 [ %27, %25 ], !dbg !417
  br i1 %29, label %90, label %30, !dbg !417, !prof !485

30:                                               ; preds = %28
  %31 = call { i1, i64 } @"pkg::t::f"(i64 %0, ptr %3), !dbg !418
  %32 = extractvalue { i1, i64 } %31, 0, !dbg !418
  br i1 %32, label %33, label %36, !dbg !418, !prof !486

33:                                               ; preds = %30
  %34 = call { i1, i64 } @"pkg::t::f"(i64 %0, ptr %3), !dbg !419
  %35 = extractvalue { i1, i64 } %34, 0, !dbg !419
  br i1 %35, label %90, label %36, !dbg !419, !prof !487

36:                                               ; preds = %30, %33
  %37 = icmp sgt i64 %0, 3, !dbg !420
  br i1 %37, label %90, label %38, !dbg !421, !prof !488

38:                                               ; preds = %36
  %39 = call { i1, i64 } @"pkg::t::g"(i64 %0, ptr %3), !dbg !422
  %40 = extractvalue { i1, i64 } %39, 0, !dbg !422
  br i1 %40, label %90, label %41, !dbg !422, !prof !489

41:                                               ; preds = %38
  %42 = call { i1, i64 } @"pkg::t::g"(i64 %0, ptr %3), !dbg !423
  %43 = extractvalue { i1, i64 } %42, 0, !dbg !423
  br i1 %43, label %90, label %44, !dbg !423, !prof !488

44:                                               ; preds = %41
  %45 = call { i1, i64 } @"pkg::t::f"(i64 %0, ptr %3), !dbg !424
  %46 = extractvalue { i1, i64 } %45, 0, !dbg !424
  br i1 %46, label %90, label %90, !dbg !424, !prof !489

90:                                               ; preds = %9, %14, %16, %23, %28, %33, %36, %38, %41, %44
  ret { i1, i64 } { i1 true, i64 undef }, !dbg !425
}

define internal { i1, i64 } @"pkg::t::nested_def::helper"(i64 %0, ptr %1) #0 !dbg !404 !prof !499 {
  %3 = call { i1, i64 } @"pkg::t::f"(i64 %0, ptr %1), !dbg !430
  %4 = extractvalue { i1, i64 } %3, 0, !dbg !430
  br i1 %4, label %5, label %5, !dbg !430, !prof !489

5:                                                ; preds = %2
  ret { i1, i64 } %3, !dbg !430
}

define internal { i1, i64 } @"pkg::t::nested_def"(i64 %0, ptr %1) #0 !dbg !405 !prof !499 {
  %3 = call { i1, i64 } @"pkg::t::nested_def::helper"(i64 %0, ptr %1), !dbg !431
  %4 = extractvalue { i1, i64 } %3, 0, !dbg !431
  br i1 %4, label %5, label %5, !dbg !431

5:                                                ; preds = %2
  ret { i1, i64 } %3, !dbg !431
}

define internal { i1, i64 } @"pkg::t::guarded"(i64 %0, ptr %1) #0 !dbg !406 !prof !499 {
  %3 = call { i1, i64 } @"pkg::t::f"(i64 %0, ptr %1), !dbg !432
  %4 = extractvalue { i1, i64 } %3, 0, !dbg !432
  br i1 %4, label %5, label %5, !dbg !432, !prof !489

5:                                                ; preds = %2
  ret { i1, i64 } %3, !dbg !433
}

define internal i64 @"pkg::t::one"(i64 %0, ptr %1) #0 !dbg !407 !prof !499 {
  %3 = call { i1, i64 } @"pkg::t::f"(i64 %0, ptr %1), !dbg !434
  %4 = extractvalue { i1, i64 } %3, 0, !dbg !434
  %5 = extractvalue { i1, i64 } %3, 1, !dbg !434
  br i1 %4, label %6, label %7, !dbg !434, !prof !490

6:                                                ; preds = %2
  ret i64 -1, !dbg !435

7:                                                ; preds = %2
  ret i64 %5, !dbg !434
}

define internal { i1, i64 } @"pkg::t::docs"(i64 %0, ptr %1) #0 !dbg !408 !prof !499 {
  %3 = call { i1, i64 } @"pkg::t::f"(i64 %0, ptr %1), !dbg !436
  %4 = extractvalue { i1, i64 } %3, 0, !dbg !436
  br i1 %4, label %5, label %5, !dbg !436, !prof !487

5:                                                ; preds = %2
  ret { i1, i64 } %3, !dbg !436
}

define internal i64 @"pkg::t::ands"(ptr %0, i64 %1) #0 !dbg !441 !prof !499 {
  %3 = getelementptr { i1, i1 }, ptr %0, i32 0, i32 0, !dbg !442
  %4 = load i1, ptr %3, align 1, !dbg !442
  br i1 %4, label %5, label %6, !dbg !443, !prof !491

5:                                                ; preds = %2
  %7 = call { i1, i1 } @"pkg::t::P::d"(ptr %0, i64 %1), !dbg !444
  %8 = extractvalue { i1, i1 } %7, 0, !dbg !444
  %9 = extractvalue { i1, i1 } %7, 1, !dbg !444
  br label %10, !dbg !443

6:                                                ; preds = %2
  br label %10, !dbg !443

10:                                               ; preds = %5, %6
  %11 = phi i1 [ false, %6 ], [ %8, %5 ], !dbg !443
  %12 = phi i1 [ false, %6 ], [ %9, %5 ], !dbg !443
  br i1 %11, label %15, label %13, !dbg !444, !prof !492

13:                                               ; preds = %10
  br i1 %12, label %14, label %15, !dbg !445, !prof !493

14:                                               ; preds = %13
  ret i64 1, !dbg !446

15:                                               ; preds = %10, %13
  ret i64 0, !dbg !447
}

define internal i64 @"pkg::t::consts"(ptr %0) #0 !dbg !451 !prof !499 {
  %2 = load i64, ptr %0, align 8, !dbg !453
  %3 = icmp eq i64 %2, 0, !dbg !453
  br i1 %3, label %4, label %5, !dbg !454, !prof !494

4:                                                ; preds = %1
  call void @"std::builtin::error::__mojo_debugger_raise_hook()"(), !dbg !455
  br label %6, !dbg !455

5:                                                ; preds = %1
  br label %6, !dbg !456

6:                                                ; preds = %4, %5
  %7 = phi i1 [ false, %5 ], [ true, %4 ], !dbg !452
  br i1 %7, label %8, label %9, !dbg !452, !prof !494

8:                                                ; preds = %6
  ret i64 -1, !dbg !457

9:                                                ; preds = %6
  ret i64 %2, !dbg !458
}

define internal { i1, i64 } @"pkg::t::sig::g"(i64 %0, ptr %1) #0 !dbg !461 !prof !499 {
  %3 = call { i1, i64 } @"pkg::t::f"(i64 %0, ptr %1), !dbg !463
  %4 = extractvalue { i1, i64 } %3, 0, !dbg !463
  br i1 %4, label %5, label %5, !dbg !463, !prof !489

5:                                                ; preds = %2
  ret { i1, i64 } %3, !dbg !463
}

define internal i64 @"pkg::t::sig"(i64 %0, ptr %1) #0 !dbg !460 !prof !499 {
  %3 = call { i1, i64 } @"pkg::t::sig::g"(i64 %0, ptr %1), !dbg !464
  %4 = extractvalue { i1, i64 } %3, 0, !dbg !464
  %5 = extractvalue { i1, i64 } %3, 1, !dbg !464
  br i1 %4, label %6, label %7, !dbg !464, !prof !495

6:                                                ; preds = %2
  ret i64 0, !dbg !465

7:                                                ; preds = %2
  ret i64 %5, !dbg !464
}

attributes #0 = { noinline }

!llvm.dbg.cu = !{!400}

!400 = distinct !DICompileUnit(language: DW_LANG_Mojo, file: !402, producer: "Mojo", isOptimized: false, runtimeVersion: 0, emissionKind: LineTablesOnly, nameTableKind: None)
!401 = !DIFile(filename: "buck-out/v2/art/cell/src/pkg/__pkg__/0123456789abcdef/src/pkg/t.mojo", directory: "")
!402 = !DIFile(filename: "tests/test_a.mojo", directory: "")
!403 = distinct !DISubprogram(name: "tries", linkageName: "pkg::t::tries", scope: !401, file: !401, line: 2, type: !438, scopeLine: 2, spFlags: DISPFlagDefinition, unit: !400)
!404 = distinct !DISubprogram(name: "helper", linkageName: "pkg::t::nested_def::helper", scope: !401, file: !401, line: 26, type: !438, scopeLine: 26, spFlags: DISPFlagDefinition, unit: !400)
!405 = distinct !DISubprogram(name: "nested_def", linkageName: "pkg::t::nested_def", scope: !401, file: !401, line: 24, type: !438, scopeLine: 24, spFlags: DISPFlagDefinition, unit: !400)
!406 = distinct !DISubprogram(name: "guarded", linkageName: "pkg::t::guarded", scope: !401, file: !401, line: 31, type: !438, scopeLine: 31, spFlags: DISPFlagDefinition, unit: !400)
!407 = distinct !DISubprogram(name: "one", linkageName: "pkg::t::one", scope: !401, file: !401, line: 34, type: !438, scopeLine: 34, spFlags: DISPFlagDefinition, unit: !400)
!408 = distinct !DISubprogram(name: "docs", linkageName: "pkg::t::docs", scope: !401, file: !401, line: 37, type: !438, scopeLine: 37, spFlags: DISPFlagDefinition, unit: !400)
!409 = distinct !DISubprogram(name: "inl", linkageName: "pkg::t::inl", scope: !401, file: !401, line: 43, type: !438, scopeLine: 43, spFlags: DISPFlagDefinition, unit: !400)
!410 = !DILocation(line: 5, column: 14, scope: !403)
!411 = !DILocation(line: 6, column: 14, scope: !403)
!412 = !DILocation(line: 7, column: 15, scope: !403)
!413 = !DILocation(line: 8, column: 17, scope: !403)
!414 = !DILocation(line: 44, column: 10, scope: !409, inlinedAt: !413)
!415 = !DILocation(line: 44, column: 5, scope: !409, inlinedAt: !413)
!416 = !DILocation(line: 46, column: 5, scope: !409, inlinedAt: !413)
!417 = !DILocation(line: 9, column: 17, scope: !403)
!418 = !DILocation(line: 11, column: 19, scope: !403)
!419 = !DILocation(line: 13, column: 19, scope: !403)
!420 = !DILocation(line: 14, column: 14, scope: !403)
!421 = !DILocation(line: 14, column: 9, scope: !403)
!422 = !DILocation(line: 17, column: 14, scope: !403)
!423 = !DILocation(line: 19, column: 15, scope: !403)
!424 = !DILocation(line: 22, column: 11, scope: !403)
!425 = !DILocation(line: 23, column: 5, scope: !403)
!430 = !DILocation(line: 27, column: 21, scope: !404)
!431 = !DILocation(line: 28, column: 22, scope: !405)
!432 = !DILocation(line: 33, column: 17, scope: !406)
!433 = !DILocation(line: 32, column: 5, scope: !406)
!434 = !DILocation(line: 35, column: 18, scope: !407)
!435 = !DILocation(line: 36, column: 13, scope: !407)
!436 = !DILocation(line: 41, column: 13, scope: !408)
!438 = !DISubroutineType(types: !{})
!441 = distinct !DISubprogram(name: "ands", linkageName: "pkg::t::ands", scope: !401, file: !401, line: 47, type: !438, scopeLine: 47, spFlags: DISPFlagDefinition, unit: !400)
!442 = !DILocation(line: 49, column: 12, scope: !441)
!443 = !DILocation(line: 49, column: 16, scope: !441)
!444 = !DILocation(line: 49, column: 23, scope: !441)
!445 = !DILocation(line: 49, column: 9, scope: !441)
!446 = !DILocation(line: 50, column: 13, scope: !441)
!447 = !DILocation(line: 53, column: 5, scope: !441)
!450 = !DIFile(filename: "oss/modular/mojo/stdlib/std/io/b.mojo", directory: "")
!451 = distinct !DISubprogram(name: "consts", linkageName: "pkg::t::consts", scope: !401, file: !401, line: 54, type: !438, scopeLine: 54, spFlags: DISPFlagDefinition, unit: !400)
!452 = !DILocation(line: 56, column: 30, scope: !451)
!453 = !DILocation(line: 281, column: 9, scope: !459, inlinedAt: !452)
!454 = !DILocation(line: 282, column: 12, scope: !459, inlinedAt: !452)
!455 = !DILocation(line: 283, column: 17, scope: !459, inlinedAt: !452)
!456 = !DILocation(line: 292, column: 9, scope: !459, inlinedAt: !452)
!457 = !DILocation(line: 58, column: 9, scope: !451)
!458 = !DILocation(line: 56, column: 9, scope: !451)
!459 = distinct !DISubprogram(name: "read_uleb128", linkageName: "std::io::b::B::read_uleb128", scope: !450, file: !450, line: 280, type: !438, scopeLine: 280, spFlags: DISPFlagDefinition, unit: !400)
!460 = distinct !DISubprogram(name: "sig", linkageName: "pkg::t::sig", scope: !401, file: !401, line: 59, type: !438, scopeLine: 59, spFlags: DISPFlagDefinition, unit: !400)
!461 = distinct !DISubprogram(name: "g", linkageName: "pkg::t::sig::g", scope: !401, file: !401, line: 61, type: !438, scopeLine: 61, spFlags: DISPFlagDefinition, unit: !400)
!463 = !DILocation(line: 64, column: 21, scope: !461)
!464 = !DILocation(line: 65, column: 17, scope: !460)
!465 = !DILocation(line: 67, column: 9, scope: !460)
!480 = !{!"branch_weights", i32 2, i32 5}
!481 = !{!"branch_weights", i32 1, i32 1}
!482 = !{!"branch_weights", i32 1, i32 6}
!483 = !{!"branch_weights", i32 0, i32 7}
!484 = !{!"branch_weights", i32 1, i32 5}
!485 = !{!"branch_weights", i32 2, i32 3}
!486 = !{!"branch_weights", i32 1, i32 3}
!487 = !{!"branch_weights", i32 0, i32 1}
!488 = !{!"branch_weights", i32 1, i32 3}
!489 = !{!"branch_weights", i32 0, i32 2}
!490 = !{!"branch_weights", i32 1, i32 2}
!491 = !{!"branch_weights", i32 4, i32 3}
!492 = !{!"branch_weights", i32 0, i32 4}
!493 = !{!"branch_weights", i32 1, i32 6}
!494 = !{!"branch_weights", i32 1, i32 3}
!495 = !{!"branch_weights", i32 2, i32 5}
!499 = !{!"function_entry_count", i64 7}
