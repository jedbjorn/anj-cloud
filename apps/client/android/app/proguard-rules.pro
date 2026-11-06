# R8 rules for the release build (spec #40 R1). The Flutter Gradle plugin adds this file to the
# release build's ProGuard files; the build type below names it as well.
#
# WorkManager's database: Room 2.6's consumer rule keeps RoomDatabase subclasses but not their
# no-argument constructor, which R8 full mode then removes, and Room creates
# androidx.work.impl.WorkDatabase_Impl by reflection: without this the release app crashes at
# start (InitializationProvider, NoSuchMethodException WorkDatabase_Impl.<init>).
-keep class * extends androidx.room.RoomDatabase { <init>(); }
