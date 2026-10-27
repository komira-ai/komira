# The NPM table kpin writes for package-lock.json (tools/build/kpin/README.md), for packages
# whose tarballs are checked in (tarballs/): the urls are placeholders no build fetches.

NPM = {
    "@fx/scoped@3.0.0": {
        "name": "@fx/scoped",
        "version": "3.0.0",
        "url": "https://registry.invalid/@fx/scoped/-/fx-scoped-3.0.0.tgz",
        "sri512": "sha512-0ExPxbJ5lBMPRQpTOmtKUYy+5TIPdOTlTvPXbFBDnKMsWw0mMN+VUeVDI4hFKXCUiLZL/kqjo3vxx95KbDCblQ==",
        "sha256": "e500150e05ee73f39079f08b00bb4ea0baf32b55fc568b5bbfdb485416801292",
        "size": 315,
    },
    "aws-cdk@2.0.0": {
        "name": "aws-cdk",
        "version": "2.0.0",
        "url": "https://registry.invalid/aws-cdk/-/aws-cdk-2.0.0.tgz",
        "sri512": "sha512-JjfoHAA03lw/hed4e5OSd/SKLiRsEY1qwPr/oS7450TmLkTFYzRy0y6LjXMdPKyuuBg5khYLKX5KafWhbuyqzA==",
        "sha256": "3626b331557ff9acac2c1e72b9a6bd991ad7a78692cafd12d9fbbe50dfc79c70",
        "size": 928,
    },
    "fx-a@1.0.0": {
        "name": "fx-a",
        "version": "1.0.0",
        "url": "https://registry.invalid/fx-a/-/fx-a-1.0.0.tgz",
        "sri512": "sha512-ywtkDJWSu5UJ5oP1SLCA/vO2H2mSNoazXY8VAREaKoKQBhlfBd/hD1kazpGN0pa+wAOFHNFI+1dJVokVkow2iw==",
        "sha256": "e12a7da2a8eb45ffd91522c5d12e8e2db416b4a2e88719c19665d6a12f4dd9c3",
        "size": 457,
    },
    "fx-b@1.0.0": {
        "name": "fx-b",
        "version": "1.0.0",
        "url": "https://registry.invalid/fx-b/-/fx-b-1.0.0.tgz",
        "sri512": "sha512-SiIODZEEWtM9Y3Q3reFOiRQmmqw+pEiy2G+e5XlPvv42QrM2LrQjuGIfS2Vh+o11g5JwyxYNrMNvDE4fksRVpg==",
        "sha256": "7cb0afcc607d011c3d2c0f29d6281fbb1d464be999e0c315fc5a0db877e2bc40",
        "size": 208,
    },
    "fx-b@2.0.0": {
        "name": "fx-b",
        "version": "2.0.0",
        "url": "https://registry.invalid/fx-b/-/fx-b-2.0.0.tgz",
        "sri512": "sha512-Unl7zZqvbchuM549gScVCTn1+UHTNDw+ct8GGXbGHaL2neE6DBdjb3Z7Y8gGCqJ5/UZahx1xezxNNvugqehIMw==",
        "sha256": "60c2033e13444716e26218ecdd0396b38eb89199a516f70ede2c057eab590247",
        "size": 208,
    },
    "fx-bundled-host@1.0.0": {
        "name": "fx-bundled-host",
        "version": "1.0.0",
        "url": "https://registry.invalid/fx-bundled-host/-/fx-bundled-host-1.0.0.tgz",
        "sri512": "sha512-erJ13p0Mi0erEXvnPFnhe607CoYyg6hC0R184pU3lz4hM86Yd3ELjRwDwcFSgirEPzgSjeUp6WRBom8fgMw+5A==",
        "sha256": "839359597967010a54176ea277ae8164604335a9ef291f3ad2201eac85f6bc86",
        "size": 350,
    },
    "fx-darwin@1.0.0": {
        "name": "fx-darwin",
        "version": "1.0.0",
        "url": "https://registry.invalid/fx-darwin/-/fx-darwin-1.0.0.tgz",
        "sri512": "sha512-tkaW2X9q0+6Sg41iLDExPAMQ5t8KpwWgrbwBkivil+QTA5sPrje8EN++V91BKgxkyWWOIPbaExtyby7enXpcsQ==",
        "sha256": "0afdb6c8bcd5f336591ebe5a93afe4e985dce862c3a681c09885b99a358f6737",
        "size": 182,
    },
}

# The checked-in tarball of each key.
FILES = {
    "@fx/scoped@3.0.0": "fx-scoped-3.0.0.tgz",
    "aws-cdk@2.0.0": "aws-cdk-2.0.0.tgz",
    "fx-a@1.0.0": "fx-a-1.0.0.tgz",
    "fx-b@1.0.0": "fx-b-1.0.0.tgz",
    "fx-b@2.0.0": "fx-b-2.0.0.tgz",
    "fx-bundled-host@1.0.0": "fx-bundled-host-1.0.0.tgz",
    "fx-darwin@1.0.0": "fx-darwin-1.0.0.tgz",
}
