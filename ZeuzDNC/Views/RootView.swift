import SwiftUI

/// Pantalla principal: la lista de programas con la barra de envio anclada
/// abajo, siempre visible.
///
/// La barra vive **fuera** del `NavigationStack` a proposito: asi no se mueve
/// al entrar y salir del editor, igual que la barra de reproduccion de
/// Spotify. Que maquina y que puerto estan elegidos es informacion que el
/// operador necesita a la vista en todo momento, no solo con un programa
/// abierto.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(ProgramStore.self) private var programs
    @Environment(\.scenePhase) private var scenePhase

    @State private var showsSettings = false

    var body: some View {
        @Bindable var model = model
        @Bindable var programs = programs

        NavigationStack {
            ProgramBrowserView(showsSettings: $showsSettings)
                .navigationDestination(isPresented: $model.showsEditor) {
                    EditorView()
                }
        }
        // Dentro del editor la barra se retira: ahi el trabajo es el texto, y
        // maquina/puerto/ENVIAR solo estorban y roban alto de pantalla. Vuelve
        // sola al salir de la edicion.
        .safeAreaInset(edge: .bottom) {
            if !model.showsEditor {
                SendBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.28), value: model.showsEditor)
        .task {
            await model.connectIfPossible()
        }
        .onChange(of: scenePhase) { _, phase in
            // En segundo plano no tiene sentido seguir sondeando el share:
            // gasta bateria y el sistema puede matar la conexion igualmente.
            switch phase {
            case .active:
                if programs.connectionState.isConnected {
                    programs.startAutoRefresh()
                }
            case .background, .inactive:
                programs.stopAutoRefresh()
            @unknown default:
                break
            }
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView()
        }
        .alert(
            "Algo salio mal",
            isPresented: Binding(
                get: { programs.errorMessage != nil },
                set: { if !$0 { programs.errorMessage = nil } }
            )
        ) {
            Button("Entendido", role: .cancel) { programs.errorMessage = nil }
        } message: {
            Text(programs.errorMessage ?? "")
        }
    }
}
