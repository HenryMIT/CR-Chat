<?php

namespace App\Tests;

use App\Services\ObjectStorage;
use App\Support\Config;
use PHPUnit\Framework\TestCase;

final class ObjectStorageTest extends TestCase
{
    // Vector oficial de AWS: "Authenticating Requests: Using Query Parameters (AWS Signature Version 4)"
    public function testFirmaCoincideConElVectorDeAws(): void
    {
        $url = ObjectStorage::presignUrl(
            'GET', 'https', 'examplebucket.s3.amazonaws.com', '/test.txt', 'us-east-1',
            'AKIAIOSFODNN7EXAMPLE', 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY', 86400, '20130524T000000Z'
        );
        $this->assertStringStartsWith('https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256', $url);
        $this->assertStringContainsString('X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request', $url);
        $this->assertStringEndsWith('X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404', $url);
    }

    public function testPutFirmaContentTypeYLongitudConElHostPublico(): void
    {
        $backup = [$_ENV, $_SERVER];
        $_ENV['MINIO_ENDPOINT'] = $_SERVER['MINIO_ENDPOINT'] = 'http://minio:9000';
        $_ENV['MINIO_PUBLIC_ENDPOINT'] = $_SERVER['MINIO_PUBLIC_ENDPOINT'] = 'http://localhost:19000';
        try {
            $storage = new ObjectStorage(new Config());
            $url = $storage->presignPublic('PUT', 'cr-chat-media', 'mensaje/2026/10/abc', 300, ['content-type' => 'image/png', 'content-length' => '10']);
        } finally {
            [$_ENV, $_SERVER] = $backup;
        }
        $this->assertStringStartsWith('http://localhost:19000/cr-chat-media/mensaje/2026/10/abc?', $url);
        $this->assertStringContainsString('X-Amz-SignedHeaders=content-length%3Bcontent-type%3Bhost', $url);
        $this->assertStringContainsString('X-Amz-Expires=300', $url);
    }
}
