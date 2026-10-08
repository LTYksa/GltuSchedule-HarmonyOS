/**
 * GltuSchedule · 鸿蒙版 —— 单元测试入口
 * 对应 Android 版各 `*Test.kt`（那边 92 个用例）
 */
import makeupResolverTest from './MakeupResolver.test';
import weekParserTest from './WeekParser.test';
import dateUtilTest from './DateUtil.test';
import holidaySyncTest from './HolidaySync.test';
import cropGeometryTest from './CropGeometry.test';

export default function testsuite() {
  makeupResolverTest();
  weekParserTest();
  dateUtilTest();
  holidaySyncTest();
  cropGeometryTest();
}
