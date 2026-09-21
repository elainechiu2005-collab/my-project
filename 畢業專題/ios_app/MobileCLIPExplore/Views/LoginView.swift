import SwiftUI

struct LoginView: View {

    @Binding var isLoggedIn: Bool

    var body: some View {

        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack {

                Spacer()

                Text("Create Account")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()

                VStack(spacing: 16) {

                    Button(action: {
                        // 暫時直接進入主畫面
                        isLoggedIn = true
                    }) {
                        SocialLoginButton(
                            imageName: "google_icon",
                            title: "Continue"
                        )
                    }
                }
                .padding(.horizontal, 24)

                Spacer()
            }
        }
    }
}

struct SocialLoginButton: View {

    let imageName: String
    let title: String

    var body: some View {

        HStack(spacing: 12) {

            Image(imageName)
                .resizable()
                .frame(width: 24, height: 24)

            Text(title)
                .font(.system(size: 21, weight: .medium))
        }
        .foregroundColor(.black)
        .frame(maxWidth: .infinity)
        .frame(height: 55)
        .background(Color.white)
        .cornerRadius(10)
    }
}

#Preview {
    LoginView(isLoggedIn: .constant(false))
}
