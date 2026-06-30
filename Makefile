EFI_GLOBAL_VARIABLE_GUID="8be4df61-93ca-11d2-aa0d-00e098032b8c"
EFI_IMAGE_SECURITY_DATABASE_GUID="d719b2cb-3d3a-4596-a3bc-dad00e67656f"

.PHONY: dependencies

all:
	git submodule update --init --recursive
	make shimriscv64.signed.efi
	make u-boot.elf

dependencies:
	sudo apt-get update
	sudo apt-get install \
	  bison \
	  efitools \
	  flex \
	  grub-efi-riscv64-unsigned \
	  libgnutls28-dev \
	  libssl-dev \
	  python3-openssl \
	  qemu-system-riscv

efi-ca.key:
	# Generate CA private key
	openssl genrsa -out efi-ca.key 4096

efi-ca.crt: efi-ca.key
	# Create CA certificate (DER, self-signed)
	openssl req -new -x509 -key efi-ca.key \
		-outform der -out efi-ca.crt -days 3650 \
		-subj "/CN=My Secure Boot CA/O=My Org/C=DE"

efi-ca.pem: efi-ca.crt
	openssl x509 -inform der -in efi-ca.crt -outform pem -out efi-ca.pem

efi.key:
	# Generate signing (vendor/leaf) private key
	openssl genrsa -out efi.key 4096

efi.csr: efi.key
	# Create signing key CSR
	openssl req -new -key efi.key -out efi.csr \
		-subj "/CN=My Secure Boot Signing Key/O=My Org/C=DE"

efi-ext.cnf:
	@printf '%s\n' \
		'basicConstraints=critical,CA:FALSE' \
		'keyUsage=critical,digitalSignature' \
		'extendedKeyUsage=critical,codeSigning' \
		'subjectKeyIdentifier=hash' \
		'authorityKeyIdentifier=keyid,issuer' \
		> efi-ext.cnf

efi.crt: efi-ca.pem efi.csr efi-ext.cnf
	# Sign leaf certificate with CA (output DER)
	openssl x509 -req -in efi.csr \
		-CAform der -CA efi-ca.crt -CAkey efi-ca.key -CAcreateserial \
		-outform der -out efi.crt -days 3650 \
		-extfile efi-ext.cnf

efi.pem: efi.crt
	# Convert leaf certificate to PEM (for enrollment tools / inspection)
	openssl x509 -inform der -in efi.crt -outform pem -out efi.pem

shimriscv64.efi: efi.pem
	cd shim && \
	make \
	-j$(nproc)
	VENDOR_CERT_FILE='../efi.crt' \
	POST_PROCESS_PE_FLAGS='-n'
	cp shim/*.efi .

grubriscv64.efi:
	cp /usr/lib/grub/riscv64-efi/monolithic/grubriscv64.efi .

shimriscv64.signed.efi: grubriscv64.efi shimriscv64.efi
	sbsign \
	--key efi.key \
	--cert efi.pem \
	--output fbriscv64.signed.efi \
	fbriscv64.efi
	sbsign \
	--key efi.key \
	--cert efi.pem \
	--output grubriscv64.signed.efi \
	grubriscv64.efi
	sbsign \
	--key efi.key \
	--cert efi.pem \
	--output mmriscv64.signed.efi \
	mmriscv64.efi
	sbsign \
	--key efi.key \
	--cert efi.pem \
	--output shimriscv64.signed.efi \
	shimriscv64.efi

PK.key:	
	openssl req -x509 -sha256 -newkey rsa:2048 -subj /CN=TEST_PK/ \
	-keyout PK.key -out PK.crt -nodes -days 3650

PK.auth: PK.key
	cert-to-efi-sig-list -g $(EFI_GLOBAL_VARIABLE_GUID) PK.crt PK.esl
	sign-efi-sig-list -c PK.crt -k PK.key PK PK.esl PK.auth

KEK.key: PK.auth
	openssl req -x509 -sha256 -newkey rsa:2048 -subj /CN=TEST_KEK/ \
	-keyout KEK.key -out KEK.crt -nodes -days 3650

KEK.auth: KEK.key
	cert-to-efi-sig-list -g $(EFI_GLOBAL_VARIABLE_GUID) KEK.crt KEK.esl
	sign-efi-sig-list -c PK.crt -k PK.key KEK KEK.esl KEK.auth

db.auth: KEK.auth efi.pem
	# 1) Create db ESL that contains the CA cert (DER)
	cert-to-efi-sig-list -g $(EFI_IMAGE_SECURITY_DATABASE_GUID) efi.pem db.esl
	# 2) Sign db.esl with KEK to create db.auth
	sign-efi-sig-list -c KEK.crt -k KEK.key db db.esl db.auth

ubootefi.var: db.auth
	rm -f ubootefi.tmp
	u-boot/tools/efivar.py set -i ubootefi.tmp -a nv,bs,rt,at \
	  -g $(EFI_GLOBAL_VARIABLE_GUID) -n PK  -d PK.esl  -t file
	u-boot/tools/efivar.py set -i ubootefi.tmp -a nv,bs,rt,at \
	  -g $(EFI_GLOBAL_VARIABLE_GUID) -n KEK -d KEK.esl -t file
	u-boot/tools/efivar.py set -i ubootefi.tmp -a nv,bs,rt,at \
	  -g $(EFI_IMAGE_SECURITY_DATABASE_GUID) -n db  -d db.esl  -t file
	u-boot/tools/efivar.py set -i ubootefi.tmp -a bs,rt,ro \
	  -g $(EFI_GLOBAL_VARIABLE_GUID) -n DeployedMode -d 1 -t u8
	mv ubootefi.tmp ubootefi.var

u-boot.elf: ubootefi.var
	cd u-boot && make qemu-riscv64_smode_defconfig ../../ubootvar.config -j$$(nproc)
	cd u-boot && make -j$$(nproc)
	cp u-boot/u-boot u-boot.elf

ubuntu-26.04-preinstalled-server-riscv64.img:
	rm -f ubuntu-26.04-preinstalled-server-riscv64.img*
	wget https://cdimage.ubuntu.com/releases/26.04/release/ubuntu-26.04-preinstalled-server-riscv64.img.xz
	xz -d ubuntu-26.04-preinstalled-server-riscv64.img.xz

run:
	qemu-system-riscv64 \
	  -M virt \
	  -m 1G \
	  -nographic \
	  -semihosting \
	  -kernel u-boot.elf

clean:
	# Keep private keys and certificates
	rm -f *.auth *.esl
	rm -f efi.*
	rm -f *.efi
	cd shim && make clean
	rm u-boot.elf
