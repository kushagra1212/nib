# One image for the Windows-targeting managed build: publishes the WPF app for
# both arches and packages the MSI. Neither step runs Windows code -- they only
# emit it, which is why this is a Linux image and not a Windows one. Docker on
# macOS cannot run Windows containers at all.
FROM mcr.microsoft.com/dotnet/sdk:9.0

# WiX v5 is a dotnet tool rather than a Windows executable, which is the whole
# reason MSI packaging can happen here instead of on a Windows runner.
RUN dotnet tool install --global wix --version 5.0.2
ENV PATH="/root/.dotnet/tools:${PATH}"
WORKDIR /src
