; *** IR Dump After PGOInstrumentationUse on [module] ***
@static_string_0 = internal constant [5 x i8] c"zero\00", align 1

define internal void @"pkg::a::pick[T=Int]"(i64 %0, i1 %1) #0 !dbg !10 !prof !73 {
2:
  %3 = icmp slt i64 %0, 0, !dbg !20
  br i1 %3, label %4, label %7, !dbg !20, !prof !60

4:                                                ; preds = %2
  %5 = call i1 @"std::builtin::string::String::__add__"(), !dbg !21
  br i1 %5, label %6, label %7, !dbg !21
  %6 = call i1 @"std::builtin::string::String::__init__"(), !dbg !22
  br i1 %6, label %7, label %8, !dbg !22

7:                                                ; preds = %2
  %8 = icmp eq i64 %0, 0, !dbg !23
  br i1 %8, label %9, label %10, !dbg !23, !prof !61
  %9 = icmp sgt i64 %0, 9, !dbg !24
  br i1 %9, label %10, label %11, !dbg !24, !prof !62
  %10 = alloca i64, i64 1, align 8, !dbg !34
  %v = select <4 x i1> %m, <4 x i64> %x, <4 x i64> %y, !dbg !34
  br label %12, !dbg !25

12:                                               ; preds = %7, %12
  %13 = icmp slt i64 %10, %0, !dbg !25
  br i1 %13, label %12, label %14, !dbg !25

14:                                               ; preds = %12
  %15 = icmp slt i64 %10, %0, !dbg !44
  br i1 %15, label %16, label %17, !dbg !44, !prof !72
  br i1 %15, label %16, label %17, !dbg !26, !prof !63
  br i1 %15, label %16, label %17, !dbg !26, !prof !63

17:                                               ; preds = %14
  %18 = icmp sgt i64 %0, 3, !dbg !27
  %19 = select i1 %18, i1 true, i1 %1, !dbg !27, !prof !64
  br i1 %19, label %20, label %21, !dbg !28, !prof !65

21:                                               ; preds = %17
  %22 = icmp sgt i64 %0, 2, !dbg !29
  %23 = select i1 %22, i1 %1, i1 false, !dbg !29, !prof !66
  br i1 %23, label %24, label %25, !dbg !30, !prof !65

25:                                               ; preds = %21
  %26 = select i1 %22, i64 0, i64 -1, !dbg !31, !prof !67
  %27 = select i1 %22, i64 1, i64 0, !dbg !32, !prof !68
  %28 = call i1 @"pkg::a::check"(i64 %26), !dbg !33
  br i1 %28, label %29, label %30, !dbg !33, !prof !69
  ret void, !dbg !34
}

define internal void @"pkg::a::pick[T=Float]"(i64 %0, i1 %1) #0 !dbg !11 !prof !73 {
2:
  %3 = icmp slt i64 %0, 0, !dbg !40
  br i1 %3, label %4, label %5, !dbg !40, !prof !70

5:                                                ; preds = %2
  %6 = icmp slt i64 %0, 1, !dbg !41
  br i1 %6, label %5, label %7, !dbg !41
  ret void, !dbg !41
}

define internal i64 @"pkg::b::f"(i64 %0) #0 !dbg !12 !prof !73 {
1:
  switch i64 %0, label %4 [
    i64 0, label %2
    i64 1, label %3
  ], !dbg !50, !prof !71

4:                                                ; preds = %1
  %5 = icmp eq i64 %0, 0, !dbg !50
  br i1 %5, label %6, label %7, !dbg !50, !prof !74
  %6 = icmp eq i64 %0, 1, !dbg !50
  br i1 %6, label %7, label %8, !dbg !50, !prof !75
  ret i64 3, !dbg !51
}

define internal i64 @"pkg::gen::g"(i64 %0) #0 !dbg !13 !prof !73 {
1:
  %2 = icmp eq i64 %0, 0, !dbg !52
  br i1 %2, label %3, label %4, !dbg !52, !prof !72
  ret i64 2, !dbg !52
}

define internal void @"test_a::main"() #0 !dbg !14 !prof !73 {
1:
  %2 = call i1 @"test_a::flag"(), !dbg !53
  br i1 %2, label %3, label %4, !dbg !53, !prof !72
  br i1 %2, label %3, label %4, !dbg !42, !prof !69
  ret void, !dbg !53
}

define internal void @"std::builtin::range::_ZeroStartingRange::__next__"() #0 !dbg !15 !prof !73 {
1:
  %2 = call i1 @"x"(), !dbg !56
  br i1 %2, label %3, label %4, !dbg !56, !prof !72
  ret void, !dbg !56
}

define internal void @"dep::d::h"() #0 !dbg !16 !prof !73 {
1:
  %2 = call i1 @"y"(), !dbg !54
  br i1 %2, label %3, label %4, !dbg !54, !prof !72
  %3 = call i1 @"z"(), !dbg !55
  br i1 %3, label %4, label %5, !dbg !55, !prof !72
  ret void, !dbg !54
}

define internal i1 @"pkg::c::spend"(i64 %0, i64 %1) #0 !dbg !101 !prof !73 {
2:
  %3 = icmp slt i64 %0, 0, !dbg !110
  br i1 %3, label %4, label %5, !dbg !111, !prof !130

4:                                                ; preds = %2
  br label %7, !dbg !111

5:                                                ; preds = %2
  %6 = icmp sgt i64 %0, %1, !dbg !112
  br label %7, !dbg !111

7:                                                ; preds = %4, %5
  %8 = phi i1 [ %6, %5 ], [ true, %4 ], !dbg !111
  %9 = select i1 %8, i1 false, i1 true, !dbg !113, !prof !131
  br i1 %8, label %10, label %11, !dbg !113, !prof !131

10:                                               ; preds = %7
  ret i1 false, !dbg !114

11:                                               ; preds = %7
  ret i1 true, !dbg !115
}

define internal i1 @"pkg::c::both"(i64 %0, i64 %1) #0 !dbg !102 !prof !73 {
2:
  %3 = icmp sgt i64 %0, 0, !dbg !116
  br i1 %3, label %4, label %6, !dbg !117, !prof !132

4:                                                ; preds = %2
  %5 = icmp sgt i64 %1, 0, !dbg !118
  br label %7, !dbg !117

6:                                                ; preds = %2
  br label %7, !dbg !117

7:                                                ; preds = %4, %6
  %8 = phi i1 [ %5, %4 ], [ false, %6 ], !dbg !117
  br i1 %8, label %9, label %10, !dbg !119, !prof !133

9:                                                ; preds = %7
  ret i1 true, !dbg !120

10:                                               ; preds = %7
  ret i1 false, !dbg !121
}

define internal i64 @"pkg::c::neg"(i1 %0, i1 %1) #0 !dbg !103 !prof !73 {
2:
  %3 = select i1 %0, i1 true, i1 %1, !dbg !122, !prof !134
  %4 = xor i1 %3, true, !dbg !123
  br i1 %4, label %5, label %6, !dbg !124, !prof !135

5:                                                ; preds = %2
  ret i64 1, !dbg !125

6:                                                ; preds = %2
  ret i64 0, !dbg !126
}

attributes #0 = { noinline }

!llvm.dbg.cu = !{!0}

!0 = distinct !DICompileUnit(language: DW_LANG_Mojo, file: !1, producer: "Mojo", isOptimized: false, runtimeVersion: 0, emissionKind: LineTablesOnly, nameTableKind: None)
!1 = !DIFile(filename: "tests/test_a.mojo", directory: "")
!2 = !DIFile(filename: "buck-out/v2/art/cell/src/pkg/__pkg__/0123456789abcdef/src/pkg/a.mojo", directory: "")
!3 = !DIFile(filename: "buck-out/v2/art/cell/src/pkg/__pkg__/0123456789abcdef/src/pkg/b.mojo", directory: "")
!4 = !DIFile(filename: "buck-out/v2/art/cell/src/pkg/__pkg__/0123456789abcdef/src/pkg/gen.mojo", directory: "")
!5 = !DIFile(filename: "oss/modular/mojo/stdlib/std/builtin/range.mojo", directory: "")
!6 = !DIFile(filename: "buck-out/v2/art/cell/src/dep/__dep__/fedcba9876543210/src/dep/d.mojo", directory: "")
!7 = !DIFile(filename: "<unknown>", directory: "")
!8 = !DIFile(filename: "buck-out/v2/art/cell/src/pkg/__pkg__/0123456789abcdef/src/pkg/c.mojo", directory: "")
!9 = !DISubroutineType(types: !{})
!10 = distinct !DISubprogram(name: "pick", linkageName: "pkg::a::pick[T=Int]", scope: !2, file: !2, line: 2, type: !9, scopeLine: 2, spFlags: DISPFlagDefinition, unit: !0)
!11 = distinct !DISubprogram(name: "pick", linkageName: "pkg::a::pick[T=Float]", scope: !2, file: !2, line: 2, type: !9, scopeLine: 2, spFlags: DISPFlagDefinition, unit: !0)
!12 = distinct !DISubprogram(name: "f", linkageName: "pkg::b::f", scope: !3, file: !3, line: 2, type: !9, scopeLine: 2, spFlags: DISPFlagDefinition, unit: !0)
!13 = distinct !DISubprogram(name: "g", linkageName: "pkg::gen::g", scope: !4, file: !4, line: 2, type: !9, scopeLine: 2, spFlags: DISPFlagDefinition, unit: !0)
!14 = distinct !DISubprogram(name: "main", linkageName: "test_a::main", scope: !1, file: !1, line: 3, type: !9, scopeLine: 3, spFlags: DISPFlagDefinition, unit: !0)
!15 = distinct !DISubprogram(name: "__next__", linkageName: "std::builtin::range::_ZeroStartingRange::__next__", scope: !5, file: !5, line: 130, type: !9, scopeLine: 130, spFlags: DISPFlagDefinition, unit: !0)
!16 = distinct !DISubprogram(name: "h", linkageName: "dep::d::h", scope: !6, file: !6, line: 1, type: !9, scopeLine: 1, spFlags: DISPFlagDefinition, unit: !0)
!17 = distinct !DILexicalBlock(scope: !10, file: !2, line: 13, column: 5)
!18 = distinct !DISubprogram(name: "x", scope: !7, file: !7, type: !9, spFlags: DISPFlagDefinition, unit: !0)
!20 = !DILocation(line: 3, column: 5, scope: !10)
!21 = !DILocation(line: 4, column: 42, scope: !10)
!22 = !DILocation(line: 4, column: 27, scope: !10)
!23 = !DILocation(line: 5, column: 5, scope: !10)
!24 = !DILocation(line: 7, column: 30, scope: !10)
!25 = !DILocation(line: 9, column: 5, scope: !10)
!26 = !DILocation(line: 11, column: 19, scope: !10)
!27 = !DILocation(line: 13, column: 14, scope: !17)
!28 = !DILocation(line: 13, column: 5, scope: !17)
!29 = !DILocation(line: 15, column: 14, scope: !10)
!30 = !DILocation(line: 15, column: 5, scope: !10)
!31 = !DILocation(line: 17, column: 18, scope: !10)
!32 = !DILocation(line: 18, column: 18, scope: !10)
!33 = !DILocation(line: 19, column: 10, scope: !10)
!34 = !DILocation(line: 8, column: 5, scope: !10)
!40 = !DILocation(line: 3, column: 5, scope: !11)
!41 = !DILocation(line: 9, column: 5, scope: !11)
!42 = !DILocation(line: 3, column: 5, scope: !10, inlinedAt: !43)
!43 = !DILocation(line: 5, column: 9, scope: !14)
!44 = !DILocation(line: 139, column: 9, scope: !15, inlinedAt: !26)
!50 = !DILocation(line: 3, column: 5, scope: !12)
!51 = !DILocation(line: 7, column: 5, scope: !12)
!52 = !DILocation(line: 3, column: 5, scope: !13)
!53 = !DILocation(line: 6, column: 9, scope: !14)
!54 = !DILocation(line: 1, column: 1, scope: !16)
!55 = !DILocation(line: 0, scope: !18)
!56 = !DILocation(line: 139, column: 9, scope: !15)
!60 = !{!"branch_weights", i32 2, i32 10}
!61 = !{!"branch_weights", i32 1, i32 9}
!62 = !{!"branch_weights", i32 3, i32 6}
!63 = !{!"branch_weights", i32 5, i32 1}
!64 = !{!"branch_weights", i32 1, i32 4}
!65 = !{!"branch_weights", i32 3, i32 2}
!66 = !{!"branch_weights", i32 4, i32 1}
!67 = !{!"branch_weights", i32 7, i32 0}
!68 = !{!"branch_weights", i32 0, i32 7}
!69 = !{!"branch_weights", i32 0, i32 1}
!70 = !{!"branch_weights", i32 1, i32 1}
!71 = !{!"branch_weights", i32 4, i32 1, i32 2}
!72 = !{!"branch_weights", i32 9, i32 9}
!73 = !{!"function_entry_count", i64 12}
!74 = !{!"branch_weights", i32 1, i32 4}
!75 = !{!"branch_weights", i32 1, i32 3}
!101 = distinct !DISubprogram(name: "spend", linkageName: "pkg::c::spend", scope: !8, file: !8, line: 2, type: !9, scopeLine: 2, spFlags: DISPFlagDefinition, unit: !0)
!102 = distinct !DISubprogram(name: "both", linkageName: "pkg::c::both", scope: !8, file: !8, line: 6, type: !9, scopeLine: 6, spFlags: DISPFlagDefinition, unit: !0)
!103 = distinct !DISubprogram(name: "neg", linkageName: "pkg::c::neg", scope: !8, file: !8, line: 10, type: !9, scopeLine: 10, spFlags: DISPFlagDefinition, unit: !0)
!110 = !DILocation(line: 3, column: 13, scope: !101)
!111 = !DILocation(line: 3, column: 17, scope: !101)
!112 = !DILocation(line: 3, column: 25, scope: !101)
!113 = !DILocation(line: 3, column: 5, scope: !101)
!114 = !DILocation(line: 4, column: 9, scope: !101)
!115 = !DILocation(line: 5, column: 5, scope: !101)
!116 = !DILocation(line: 7, column: 10, scope: !102)
!117 = !DILocation(line: 7, column: 14, scope: !102)
!118 = !DILocation(line: 7, column: 20, scope: !102)
!119 = !DILocation(line: 7, column: 5, scope: !102)
!120 = !DILocation(line: 8, column: 9, scope: !102)
!121 = !DILocation(line: 9, column: 5, scope: !102)
!122 = !DILocation(line: 11, column: 15, scope: !103)
!123 = !DILocation(line: 11, column: 8, scope: !103)
!124 = !DILocation(line: 11, column: 5, scope: !103)
!125 = !DILocation(line: 12, column: 9, scope: !103)
!126 = !DILocation(line: 14, column: 5, scope: !103)
!127 = !DILocation(line: 13, column: 15, scope: !103)
!128 = !DILocation(line: 12, column: 21, scope: !103)
!130 = !{!"branch_weights", i32 1, i32 5}
!131 = !{!"branch_weights", i32 3, i32 3}
!132 = !{!"branch_weights", i32 4, i32 2}
!133 = !{!"branch_weights", i32 3, i32 3}
!134 = !{!"branch_weights", i32 3, i32 4}
!135 = !{!"branch_weights", i32 2, i32 5}
