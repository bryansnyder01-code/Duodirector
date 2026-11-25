import SwiftUI

// =====================================================================================
//  AboutView (Phase 10): version, privacy policy link, open-source acknowledgements
//
//  The BSD-3-Clause license REQUIRES HaishinKit's copyright notice and license text to
//  be reproduced in the app. VERIFY the text below against the LICENSE file of the
//  HaishinKit version Xcode resolved (Package.resolved) before submitting.
// =====================================================================================

struct AboutView: View {
    /// Set this to the hosted copy of docs/PRIVACY_POLICY.md before submitting.
    static let privacyPolicyURL = URL(string: "https://bryansnyder01-code.github.io/Duodirector/privacy/")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image("AppLogo")
                        .resizable().scaledToFit()
                        .frame(width: 96, height: 96)
                        .clipShape(.rect(cornerRadius: 22, style: .continuous))
                        .accessibilityHidden(true)
                    Text(verbatim: "DuoDirector").font(.title2.bold())
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            Section {
                LabeledContent("Version", value: version)
                Link("Privacy policy", destination: Self.privacyPolicyURL)
            }
            Section {
                ForEach(Acknowledgement.all) { a in
                    NavigationLink(a.name) {
                        ScrollView {
                            Text(a.license).font(.footnote.monospaced()).padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .navigationTitle(a.name)
                    }
                }
            } header: {
                Text("Acknowledgements")
            } footer: {
                Text("DuoDirector is built with these open-source projects.")
            }
        }
        .navigationTitle("About")
    }
}

struct Acknowledgement: Identifiable {
    let name: String
    let license: String
    var id: String { name }

    static let all: [Acknowledgement] = [haishinKit]

    static let haishinKit = Acknowledgement(name: "HaishinKit", license: """
    BSD 3-Clause License

    Copyright (c) 2015, shogo4405
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice, this
       list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright notice,
       this list of conditions and the following disclaimer in the documentation
       and/or other materials provided with the distribution.

    3. Neither the name of the copyright holder nor the names of its
       contributors may be used to endorse or promote products derived from
       this software without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
    AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
    IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
    DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
    FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
    DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
    SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
    OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
    OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
    """)
}
