using System.Text;
using Azure.Identity;
using Azure.Storage.Blobs;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace UrbanMobility.RawProducer;

public class CityBikesRawProducer
{
    private static readonly HttpClient HttpClient = new();

    private readonly ILogger<CityBikesRawProducer> _logger;

    public CityBikesRawProducer(ILogger<CityBikesRawProducer> logger)
    {
        _logger = logger;
    }

    [Function("CityBikesRawProducer")]
    public async Task Run([TimerTrigger("0 */30 * * * *", RunOnStartup = true)] TimerInfo timer)
    {
        var storageAccountName = GetRequiredSetting("LAKEHOUSE_STORAGE_NAME");
        var landingContainerName = GetRequiredSetting("LANDING_CONTAINER_NAME");

        var networkIds = GetRequiredSetting("CITYBIKES_NETWORK_IDS")
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

        var ingestionTs = DateTimeOffset.UtcNow;
        var loadDate = ingestionTs.ToString("yyyy-MM-dd");
        var loadTs = ingestionTs.ToString("yyyyMMddTHHmmssZ");

        var blobServiceClient = new BlobServiceClient(
            new Uri($"https://{storageAccountName}.blob.core.windows.net"),
            new DefaultAzureCredential()
        );

        var containerClient = blobServiceClient.GetBlobContainerClient(landingContainerName);

        foreach (var networkId in networkIds)
        {
            var url = $"https://api.citybik.es/v2/networks/{networkId}";

            _logger.LogInformation("Calling CityBikes API for network {NetworkId}", networkId);

            var rawJson = await HttpClient.GetStringAsync(url);

            var blobName =
                $"citybikes/{networkId}/network_snapshot/" +
                $"load_date={loadDate}/" +
                $"{networkId}_{loadTs}.json";

            var blobClient = containerClient.GetBlobClient(blobName);

            using var stream = new MemoryStream(Encoding.UTF8.GetBytes(rawJson));

            await blobClient.UploadAsync(stream, overwrite: true);

            _logger.LogInformation("Written raw snapshot to landing: {BlobName}", blobName);
        }
    }

    private static string GetRequiredSetting(string name)
    {
        return Environment.GetEnvironmentVariable(name)
            ?? throw new InvalidOperationException($"Missing required setting: {name}");
    }
}