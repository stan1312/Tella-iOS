platform :ios, '15.0'

target 'Tella' do
  # Comment the next line if you don't want to use dynamic frameworks
  #use_frameworks!
  use_modular_headers!

  pod 'SQLCipher', ">= 4.5.2"
  pod 'ZIPFoundation'
  pod 'GoogleSignIn', '~> 9.1'
  pod 'GoogleAPIClientForREST/Drive'
  pod 'SwiftyDropbox'
  
  target 'TellaTests' do
    inherit! :search_paths
    # Pods for testing
  end

  # SPECTRE Capture app-hosted tests (see scripts/xcode_add_spectre_app_tests.rb)
  target 'SpectreAppTests' do
    inherit! :search_paths
  end

  target 'TellaUITests' do
    # Pods for testing
  end

end
