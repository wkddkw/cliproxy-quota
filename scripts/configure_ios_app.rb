# Idempotently disable the home-screen extension; release v0.1.3 is app-only.
require 'xcodeproj'
project = Xcodeproj::Project.open(File.join(__dir__, '../ios/Runner.xcodeproj'))
runner = project.targets.find { |target| target.name == 'Runner' }
project.targets.select { |target| target.name == 'QuotaWidget' }.each do |widget|
  runner.dependencies.select { |dependency| dependency.target == widget }.each(&:remove_from_project)
  runner.copy_files_build_phases.select { |phase| phase.display_name == 'Embed App Extensions' }.each(&:remove_from_project)
  widget.product_reference.remove_from_project
  widget.remove_from_project
end
project.main_group.find_subpath('QuotaWidget')&.remove_from_project
runner.build_configurations.each do |config|
  config.build_settings.delete('CODE_SIGN_ENTITLEMENTS')
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
end
project.save
