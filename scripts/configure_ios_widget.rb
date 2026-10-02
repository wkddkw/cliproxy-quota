# Run with: gem install xcodeproj && ruby scripts/configure_ios_widget.rb
# Committed project already contains the target; this script is idempotent.
require 'xcodeproj'
project = Xcodeproj::Project.open(File.join(__dir__, '../ios/Runner.xcodeproj'))
runner = project.targets.find { |target| target.name == 'Runner' }
runner.build_configurations.each do |config|
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
end
unless project.targets.any? { |target| target.name == 'QuotaWidget' }
  widget = project.new_target(:app_extension, 'QuotaWidget', :ios, '17.0')
  group = project.main_group.new_group('QuotaWidget', 'QuotaWidget')
  source = group.new_file('QuotaWidget.swift')
  group.new_file('Info.plist')
  group.new_file('QuotaWidget.entitlements')
  widget.add_file_references([source])
  widget.add_system_framework('WidgetKit')
  widget.add_system_framework('SwiftUI')
  widget.build_configurations.each do |config|
    config.build_settings.merge!({
      'PRODUCT_BUNDLE_IDENTIFIER' => 'com.wkddkw.cliproxyQuota.QuotaWidget',
      'PRODUCT_NAME' => '$(TARGET_NAME)',
      'INFOPLIST_FILE' => 'QuotaWidget/Info.plist',
      'CODE_SIGN_ENTITLEMENTS' => 'QuotaWidget/QuotaWidget.entitlements',
      'SWIFT_VERSION' => '5.0', 'SKIP_INSTALL' => 'YES',
      'MARKETING_VERSION' => '0.1.0', 'CURRENT_PROJECT_VERSION' => '1',
      'TARGETED_DEVICE_FAMILY' => '1,2', 'APPLICATION_EXTENSION_API_ONLY' => 'YES',
      'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks'],
      'CODE_SIGN_STYLE' => 'Automatic'
    })
  end
  # Runner has a Profile configuration; the extension must match it.
  unless widget.build_configurations.any? { |c| c.name == 'Profile' }
    profile = widget.add_build_configuration('Profile', :release)
    profile.build_settings = widget.build_configurations.find { |c| c.name == 'Release' }.build_settings.dup
  end
  runner.add_dependency(widget)
  embed = runner.new_copy_files_build_phase('Embed App Extensions')
  embed.dst_subfolder_spec = '13'
  embed.add_file_reference(widget.product_reference).settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end
widget = project.targets.find { |target| target.name == 'QuotaWidget' }
version = File.read(File.join(__dir__, '../pubspec.yaml')).match(/^version:\s+(\S+)\+(\d+)/)
widget.build_configurations.each do |config|
  config.build_settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  config.build_settings['MARKETING_VERSION'] = version[1]
  config.build_settings['CURRENT_PROJECT_VERSION'] = version[2]
end
group = project.main_group.find_subpath('QuotaWidget')
unless group.files.any? { |file| file.path == 'Assets.xcassets' }
  assets = group.new_file('Assets.xcassets')
  widget.resources_build_phase.add_file_reference(assets)
end
embed = runner.build_phases.find { |phase| phase.display_name == 'Embed App Extensions' }
thin = runner.build_phases.find { |phase| phase.display_name == 'Thin Binary' }
if embed && thin
  runner.build_phases.delete(embed)
  runner.build_phases.insert(runner.build_phases.index(thin), embed)
end
project.save
