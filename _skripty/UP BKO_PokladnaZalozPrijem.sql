USE [HeliosSCS001]
GO

/* info: Vytvoøení definice uložené procedury BKO_PokladnaZalozPrijem
(používaná pro pøenos výdajového PD do pøíjmového PD na HPS) */

SET NOCOUNT ON;
GO

-- pustíme pøípadnou døívìjší definici uložené procedury
IF OBJECT_ID('[dbo].BKO_PokladnaZalozPrijem', 'P') IS NOT NULL
    DROP PROCEDURE [dbo].BKO_PokladnaZalozPrijem;
GO

-- deklarujeme uloženou proceduru znovu
CREATE PROCEDURE [dbo].BKO_PokladnaZalozPrijem
	@chvnCilovaRadaDokladu		NVARCHAR(3),			-- cílová øada dokladù (cílová pokladna)
	@intID						INTEGER					-- ID výchozího záznamu (výdajového PD)
AS

    -- pseudo-konstanty
	DECLARE @inyFIXVydajovyPD   TINYINT = 16;			-- výdajový pokladní doklad
	DECLARE @inyFIXPrijmovyPD	TINYINT = 17;			-- pøíjmový pokladní doklad
	DECLARE @inyFIXBezRozlisDD  TINYINT = 0;			-- zpùsob èíslování bez rozlišení DD
	DECLARE @inyFIXRozliseniDD  TINYINT = 1;			-- zpùsob èíslování podle DD
	DECLARE @intFIXKontaceVyde  INTEGER = 700004;		-- požadovaná kontace výdajového dokladu
	DECLARE @intFIXKontacePrij  INTEGER = 710004;		-- požadovaná kontace pøíjmového dokladu

	-- promìnné
	DECLARE @inyTypDokladu		TINYINT;				-- zdrojový typ dokladu
	DECLARE @chvnErrMsg			NVARCHAR(200);			-- text chybového hlášení
	DECLARE @intIDDruhPokl      INTEGER = 0;			-- ID záznamu druhu pokladny
	DECLARE @chvnMenaZdrojova	NVARCHAR(3);			-- mìna zdrojové pokladny
	DECLARE @chvnMenaCilova		NVARCHAR(3);			-- mìna cílové pokladny
	DECLARE @intNovePoradi		INTEGER;				-- poøadové èíslo pro novì vytváøený doklad
	DECLARE @intObdobi			INTEGER;				-- období dokladu
	DECLARE @chvnZdrojovaRada   NVARCHAR(3);			-- zdrojová øada dokladù (zdrojová pokladna)
	DECLARE @inyZpusobCislovani TINYINT;				-- zpùsob èíslování (0 = bez rozlišení druhu dokladu, 1 = podle druhu dokladu)
	DECLARE @intStartPrijem     INTEGER;				-- poèáteèní èíslo pøíjmových dokladù
	DECLARE @intKontace			INTEGER;				-- kontace výchozího dokladu

	-- vytáhneme typ dokladu zpracovávaného pokladního dokladu,
	-- (16 = výdaj z pokladny, 17 = pøíjem do pokladny)
	-- jeho øadu dokladù, období
	SELECT	@inyTypDokladu = Pokl.TypDokladu, 
			@chvnZdrojovaRada = Pokl.RadaDokladuPokl,
			@intObdobi = Pokl.Obdobi,
			@intKontace = Pokl.UKod
	FROM dbo.TabPokladna Pokl
	WHERE Pokl.ID = @intID;

	IF ( @inyTypDokladu = @inyFIXVydajovyPD )
	BEGIN
		-- máme výdajový doklad -> mùžeme tvoøit pøíjem

		-- oznaèení cílové pokladny mohlo být zadáno i z klávesnice, takže ovìøíme
		-- jestli je smysluplné a ve shodné mìnì jako pokladna výchozí
		SELECT	@intIDDruhPokl = Druh.ID, 
				@chvnMenaCilova = Druh.Mena
		FROM dbo.TabDruhPokladen Druh
		WHERE Druh.Cislo = @chvnCilovaRadaDokladu;

		IF ( @intIDDruhPokl IS NULL ) OR ( @intIDDruhPokl = 0 )
			-- cílová pokladna nenalezena
			SET @chvnErrMsg = N'Urèená cílová pokladna nebyla nalezena.';
		ELSE
		BEGIN
			-- cílová pokladna nalezena -> testujeme shodu mìn
			SELECT @chvnMenaZdrojova = Druh.Mena
			FROM dbo.TabPokladna Pokl
			INNER JOIN dbo.TabDruhPokladen Druh ON Druh.Cislo = Pokl.RadaDokladuPokl 
			WHERE Pokl.ID = @intID;

			IF @chvnMenaCilova = @chvnMenaZdrojova
			BEGIN
				-- shoda v mìnách -> pokraèujeme

				IF @chvnZdrojovaRada = @chvnCilovaRadaDokladu
					-- zdrojová i cílová pokladna jsou shodné -> nelze
					SET @chvnErrMsg = N'Cílová pokladna musí být jiná než pokladna zdrojová.';
				
				ELSE
				BEGIN
					-- zdrojová i cílová pokladna jsou rùzné -> pokraèujeme

					IF ( @intKontace IS NULL ) OR ( @intKontace <> @intFIXKontaceVyde )
						-- kontace na zdrojovém dokladu nemá požadovanou hodnotu -> nelze
						SET @chvnErrMsg = N'Úèetní kód výchozího dokladu musí být ' + CAST( @intFIXKontaceVyde AS NVARCHAR(6) ) + '.';

					ELSE
					BEGIN
						-- kontace na zdrojovém dokladu je v poøádku -> pokraèujeme

						-- vyzvedneme charakteristiky èíslování dokladù
						SELECT 	@inyZpusobCislovani = DefP.ZpusobCislovani,
								@intStartPrijem = DefP.StartPrijem
						FROM dbo.TabDruhPoDef DefP
						WHERE DefP.IdDruhPo = @intIDDruhPokl
						AND DefP.IdObdobi = @intObdobi
						AND DefP.Blokovano = 0;

						-- potøebujeme poøadové èíslo pro cílový doklad
						-- podle zpùsobu èíslování hledáme maximum pøes všechny doklady (pro zpùsob èíslování 0 - bez rozlišení DD)
						-- nebo maximum pøes pøíjmové pokladní doklady (pro zpùsob 1 - podle DD)
						SELECT @intNovePoradi = MAX( Pokl.PoradoveCislo )
						FROM dbo.TabPokladna Pokl
						WHERE Pokl.Obdobi = @intObdobi
						AND Pokl.RadaDokladuPokl = @chvnCilovaRadaDokladu
						AND Pokl.TypDokladu = CASE WHEN @inyZpusobCislovani = @inyFIXBezRozlisDD THEN Pokl.TypDokladu ELSE @inyFIXPrijmovyPD END;

						IF @intNovePoradi IS NULL
							-- pokud žádný doklad zatím nemáme, zaèneme èíslovat podle nastavení
							SET @intNovePoradi = @intStartPrijem
						ELSE
							-- nìjaké doklady máme -> bereme další èíslo v poøadí
							SET @intNovePoradi = @intNovePoradi + 1;

						-- vkládáme nový pøíjmový doklad
						INSERT INTO dbo.TabPokladna ( /* 01 */ [TypDokladu], [StavDokladu], [PoradoveCislo], [RadaDokladuPokl], [IDPomTxt],
													  /* 02 */ [Popis], [Poznamka], [Prilohy], [Obdobi], [IdObdobiStavu],
													  /* 03 */ [DatPorizeno], [DatPripad], [DUZP], [DatUctovani], [CisloOrg],
													  /* 04 */ [DIC], [CisloZam], [KontaktOsoba], [ParovaciZnak], [ZalohovyDoklad],
													  /* 05 */ [Ukod], [IDSklad], [CisloZakazky], [CisloNakladovyOkruh], [IdVozidlo],
													  /* 06 */ [DatPorizeni], [Autor], [DatZmeny], [Zmenil], [Mena],
													  /* 07 */ [CastkaMena], [DatumKurz], [Kurz], [JednotkaMeny], [KurzEuro],
													  /* 08 */ [RucniZadaniKurzu], [IdPrijmyVydaje], [SamoVyDICDPH], [IdDanovyRezim], [IdDanovyKlic1],
													  /* 09 */ [IdDanovyKlic2], [IdDanovyKlic3], [IdDanovyKlic4], [VcetneDPH1CM], [VcetneDPH2CM],
													  /* 10 */ [VcetneDPH3CM], [VcetneDPH4CM], [OstatniCM], [DatumKurzDoklad], [KurzDoklad],
													  /* 11 */ [MnozstviDoklad], [KurzEuroDoklad], [ZalohaCM], [DatumKurzZaloha], [KurzZaloha],
													  /* 12 */ [MnozstviZaloha], [KurzEuroZaloha], [SazbaDPH1], [SazbaDPH2], [SazbaDPH3],
													  /* 13 */ [SazbaDPH4], [ZakladDPH1], [ZakladDPH2], [ZakladDPH3], [ZakladDPH4],
													  /* 14 */ [CastkaDPH1], [CastkaDPH2], [CastkaDPH3], [CastkaDPH4], [CelkemDPH1],
													  /* 15 */ [CelkemDPH2], [CelkemDPH3], [CelkemDPH4], [Ostatni], [Uhrada],
													  /* 16 */ [Zaloha], [TypPolozek], [ZpusobPrepoctu], [VerzePokladny], [OrganizaceTransakce],
													  /* 17 */ [BlokovaniEditoru], [KumVydaj], [StavPokladny], [StavPokladnyCM], [StavPokladnyCM01],
													  /* 18 */ [StavPokladnyCM02], [StavPokladnyCM03], [StavPokladnyCM04], [StavPokladnyCM05], [StavPokladnyCM06],
													  /* 19 */ [StavPokladnyCM07], [StavPokladnyCM08], [StavPokladnyCM09], [StavPokladnyCM10], [StavPokladnyCM11],
													  /* 20 */ [StavPokladnyCM12], [StavPokladnyCM13], [StavPokladnyCM14], [StavPokladnyCM15], [StavPokladnyCM16],
													  /* 21 */ [StavPokladnyCM17], [StavPokladnyCM18], [StavPokladnyCM19], [StavPokladnyCM20], [Zustatek],
													  /* 22 */ [ZustatekCM], [ZustatekCM01], [ZustatekCM02], [ZustatekCM03], [ZustatekCM04],
													  /* 23 */ [ZustatekCM05], [ZustatekCM06], [ZustatekCM07], [ZustatekCM08], [ZustatekCM09],
													  /* 24 */ [ZustatekCM10], [ZustatekCM11], [ZustatekCM12], [ZustatekCM13], [ZustatekCM14],
													  /* 25 */ [ZustatekCM15], [ZustatekCM16], [ZustatekCM17], [ZustatekCM18], [ZustatekCM19],
													  /* 26 */ [ZustatekCM20], [IDJCDFa], [NavaznyDoklad], [PoziceZaokrDPH], [HraniceZaokrDPH],
													  /* 27 */ [KoeficientProDPH], [ZaokrPoklDokNa50], [ZaokrUhrady], [KHDPHDoLimitu], [PlneniDoLimitu],
													  /* 28 */ [DodFakKV], [StavEET], [EETStorno]
													)
						SELECT	/* 01 */ @inyFIXPrijmovyPD, [StavDokladu], @intNovePoradi, @chvnCilovaRadaDokladu, [IDPomTxt],
								/* 02 */ [Popis], [Poznamka], [Prilohy], [Obdobi], [IdObdobiStavu],
								/* 03 */ [DatPorizeno], [DatPripad], [DUZP], NULL, [CisloOrg],
								/* 04 */ [DIC], [CisloZam], [KontaktOsoba], [ParovaciZnak], [ZalohovyDoklad],
								/* 05 */ @intFIXKontacePrij, [IDSklad], [CisloZakazky], [CisloNakladovyOkruh], [IdVozidlo],
								/* 06 */ GETDATE(), SUSER_SNAME(), NULL, NULL, [Mena],
								/* 07 */ [CastkaMena], [DatumKurz], [Kurz], [JednotkaMeny], [KurzEuro],
								/* 08 */ [RucniZadaniKurzu], [IdPrijmyVydaje], [SamoVyDICDPH], [IdDanovyRezim], [IdDanovyKlic1],
								/* 09 */ [IdDanovyKlic2], [IdDanovyKlic3], [IdDanovyKlic4], [VcetneDPH1CM], [VcetneDPH2CM],
								/* 10 */ [VcetneDPH3CM], [VcetneDPH4CM], [OstatniCM], [DatumKurzDoklad], [KurzDoklad],
								/* 11 */ [MnozstviDoklad], [KurzEuroDoklad], [ZalohaCM], [DatumKurzZaloha], [KurzZaloha],
								/* 12 */ [MnozstviZaloha], [KurzEuroZaloha], [SazbaDPH1], [SazbaDPH2], [SazbaDPH3],
								/* 13 */ [SazbaDPH4], [ZakladDPH1], [ZakladDPH2], [ZakladDPH3], [ZakladDPH4],
								/* 14 */ [CastkaDPH1], [CastkaDPH2], [CastkaDPH3], [CastkaDPH4], [CelkemDPH1],
								/* 15 */ [CelkemDPH2], [CelkemDPH3], [CelkemDPH4], [Ostatni], [Uhrada],
								/* 16 */ [Zaloha], [TypPolozek], [ZpusobPrepoctu], [VerzePokladny], [OrganizaceTransakce],
								/* 17 */ NULL, [KumVydaj], [StavPokladny], [StavPokladnyCM], [StavPokladnyCM01],
								/* 18 */ [StavPokladnyCM02], [StavPokladnyCM03], [StavPokladnyCM04], [StavPokladnyCM05], [StavPokladnyCM06],
								/* 19 */ [StavPokladnyCM07], [StavPokladnyCM08], [StavPokladnyCM09], [StavPokladnyCM10], [StavPokladnyCM11],
								/* 20 */ [StavPokladnyCM12], [StavPokladnyCM13], [StavPokladnyCM14], [StavPokladnyCM15], [StavPokladnyCM16],
								/* 21 */ [StavPokladnyCM17], [StavPokladnyCM18], [StavPokladnyCM19], [StavPokladnyCM20], [Zustatek],
								/* 22 */ [ZustatekCM], [ZustatekCM01], [ZustatekCM02], [ZustatekCM03], [ZustatekCM04],
								/* 23 */ [ZustatekCM05], [ZustatekCM06], [ZustatekCM07], [ZustatekCM08], [ZustatekCM09],
								/* 24 */ [ZustatekCM10], [ZustatekCM11], [ZustatekCM12], [ZustatekCM13], [ZustatekCM14],
								/* 25 */ [ZustatekCM15], [ZustatekCM16], [ZustatekCM17], [ZustatekCM18], [ZustatekCM19],
								/* 26 */ [ZustatekCM20], [IDJCDFa], [NavaznyDoklad], [PoziceZaokrDPH], [HraniceZaokrDPH],
								/* 27 */ [KoeficientProDPH], [ZaokrPoklDokNa50], [ZaokrUhrady], [KHDPHDoLimitu], [PlneniDoLimitu],
								/* 28 */ [DodFakKV], 2, NULL
						FROM dbo.TabPokladna
						WHERE ID = @intID;

					END;

				END;

			END
			ELSE
				-- neshoda v mìnách -> chyba
				SET @chvnErrMsg = N'Cílová pokladna je v jiné mìnì než pokladna zdrojová.';
		END;
	   
	END
	ELSE
		-- nemáme výdajový doklad -> chyba
		SET @chvnErrMsg = N'Akce je urèena pouze pro výdajové pokladní doklady.';

	IF @chvnErrMsg <> ''
		RAISERROR( @chvnErrMsg, 16, 1 );
GO