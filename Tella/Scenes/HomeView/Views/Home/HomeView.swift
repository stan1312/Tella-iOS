//
//  Copyright © 2021 HORIZONTAL. 
//  Licensed under MIT (https://github.com/Horizontal-org/Tella-iOS/blob/develop/LICENSE)
//


import SwiftUI

struct HomeView: View {

    @EnvironmentObject private var sheetManager: SheetManager
    
    @ObservedObject var viewModel: HomeViewModel

    @ObservedObject var mainAppModel: MainAppModel

    var body: some View {
        
        ContainerViewWithHeader {
            navigationBarView
        } content: {
            contentView
        }
        .onAppear {
            viewModel.getFiles()
        }
    }
    
    var contentView: some View {
        VStack() {
            ScrollView {
                VStack {
                    // SPECTRE: deposit status (with the demonstration of the day),
                    // then two capture buttons whose recordings go to the deposit.
                    SpectreHomeCard(service: mainAppModel.spectre)
                        .padding(.top, 12)
                    SpectreCaptureButtons(mainAppModel: mainAppModel)
                        .padding(.top, 16)
                    Spacer()
                        .frame(height: 32)
                    ConnectionsView(homeViewModel: viewModel)
                }
            }
            
            Spacer()
            
            quickDeleteView
        }
    }
    
    @ViewBuilder
    var quickDeleteView: some View {
        if mainAppModel.settings.quickDelete {
            SwipeToDeleteActionView(completion: {
                if mainAppModel.settings.deleteVault {
                    // removes files and folders
                    viewModel.deleteAllVaultFiles()
                }
                
                if mainAppModel.settings.deleteServerSettings {
                    // remove servers connections
                    viewModel.deleteAllServersConnection()
                }
                
                viewModel.appViewState.resetToUnlock()
            })
        }
    }
    
    var navigationBarView : some View {
        
        HStack(spacing: 0) {
            
            Button() {
                showTopSheetView(content: BackgroundActivitiesView(mainAppModel: mainAppModel))
            } label: {
                Image(viewModel.items.count > 0 ? "home.notification_badge" : "home.notificaiton")
                    .padding()
            }
            
            Spacer()
            
            Text("SPECTRE")
                .font(.custom(Styles.Fonts.boldFontName, size: 20))
                .kerning(3)
                .foregroundColor(Color.white)
            
            Spacer()
            
            Button {
                viewModel.items.count > 0 ? showBgEncryptionConfirmationView() : viewModel.appViewState.resetToUnlock()
            } label: {
                Image(systemName: "lock")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(.white)
                    .frame(width: 35, height: 35)
                    .accessibilityLabel("Verrouiller")
            }
        }.frame(height: 57)
            .padding(.horizontal, 16)
    }
    
    private func showBgEncryptionConfirmationView() {
        sheetManager.showBottomSheet() {
            ConfirmBottomSheet(titleText: LocalizableBackgroundActivities.exitSheetTitle.localized,
                               msgText: LocalizableBackgroundActivities.exitSheetExpl.localized,
                               cancelText: LocalizableBackgroundActivities.exitcancelSheetAction.localized,
                               actionText: LocalizableBackgroundActivities.exitDiscardSheetAction.localized, didConfirmAction: {
                viewModel.appViewState.resetToUnlock()
                sheetManager.hide()
            })
        }
    }
}

//struct HomeView_Previews: PreviewProvider {
//    static var previews: some View {
//        HomeView(viewModel: HomeViewModel.stub())
//    }
//}
